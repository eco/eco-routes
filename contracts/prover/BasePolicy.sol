// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPolicy} from "../interfaces/IPolicy.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Reward, RewardToken} from "../types/Intent.sol";
import {RewardMath} from "../libs/RewardMath.sol";

/**
 * @title BasePolicy
 * @notice Base implementation for intent proving contracts (v3 hash-only fact model)
 * @dev Provides core storage and functionality for tracking proven intents. The destination
 *      fulfillment fact and the cross-chain proof are HASH-ONLY: the prover stores and forwards a
 *      `fulfillmentHash`, never the claimant. The claimant + per-leg amounts are supplied as a preimage
 *      at settle. {previewRelease} turns the verified `fulfilled[]` into per-leg reward amounts (the
 *      atomic rate+flat curve) for the Account to cap and pay.
 */
abstract contract BasePolicy is IPolicy, ERC165 {
    /**
     * @notice Address of the Portal contract
     * @dev Immutable to prevent unauthorized changes
     */
    address public immutable PORTAL;

    /**
     * @notice Local chain id, cached for gas efficiency
     * @dev Prepended to the proof message this prover dispatches so the source chain can bind the
     *      fulfillment to its destination. Equal to the local Portal's chain id (same chain).
     */
    uint64 public immutable CHAIN_ID;

    /**
     * @notice Mapping from intent hash to proof data
     * @dev Empty struct (zero fulfillmentHash) indicates intent hasn't been proven
     */
    mapping(bytes32 => ProofData) internal _provenIntents;

    /**
     * @notice DESTINATION fulfillment store: intent hash to the recorded fulfillment commitment
     * @dev Written by {recordFulfillment} (only the local Portal). Zero means the intent has not been
     *      fulfilled on this chain under this prover. Stores the `fulfillmentHash` (a commitment to the
     *      claimant + delivered amounts), never the claimant itself. One slot per intent — a second
     *      fulfillment reverts.
     */
    mapping(bytes32 => bytes32) internal _destFulfillment;

    /**
     * @notice Get proof data for an intent
     * @param intentHash The intent hash to query
     * @return ProofData struct containing destination and fulfillment commitment
     */
    function provenIntents(
        bytes32 intentHash
    ) external view returns (ProofData memory) {
        return _provenIntents[intentHash];
    }

    /**
     * @notice Get the destination fulfillment commitment recorded for an intent on this chain
     * @param intentHash The intent hash to query
     * @return The recorded fulfillmentHash, or zero if unfulfilled
     */
    function destFulfillment(
        bytes32 intentHash
    ) external view returns (bytes32) {
        return _destFulfillment[intentHash];
    }

    /**
     * @notice Initializes the BasePolicy contract
     * @param portal Address of the Portal contract
     */
    constructor(address portal) {
        if (portal == address(0)) {
            revert ZeroPortal();
        }

        PORTAL = portal;

        if (block.chainid > type(uint64).max) {
            revert ChainIdTooLarge(block.chainid);
        }
        CHAIN_ID = uint64(block.chainid);
    }

    /**
     * @notice Records a destination-chain fulfillment for an intent
     * @dev Only the local Portal may call this. Enforces a one-shot gate ({IntentAlreadyFulfilled}). The
     *      `destination` argument is implied by {CHAIN_ID} at proof-build time, so it is not stored.
     * @param intentHash Hash of the fulfilled intent
     * @param fulfillmentHash Commitment to the proven `(intentHash, claimant, fulfilled[])` tuple
     */
    function recordFulfillment(
        bytes32 intentHash,
        uint64 /* destination */,
        bytes32 fulfillmentHash
    ) external virtual {
        if (msg.sender != PORTAL) {
            revert NotPortal(msg.sender);
        }
        if (_destFulfillment[intentHash] != bytes32(0)) {
            revert IntentAlreadyFulfilled(intentHash);
        }
        _destFulfillment[intentHash] = fulfillmentHash;
    }

    /**
     * @notice The atomic rate+flat reward curve (pure view consulted by the Account at settle)
     * @dev PAIRED legs (`j < fulfilled.length`): `fulfilled[j] * rate / WAD + flat`. EXTRA legs (`j >=
     *      fulfilled.length`): `flat` (rate ignored). Result index-aligned with `reward.tokens`; the
     *      Account caps each entry at its own balance and sweeps the residual to the keeper.
     * @param reward The reward specification
     * @param fulfilled The core-verified per-leg delivered amounts (paired prefix)
     * @return payNow Per-leg uncapped reward amount
     */
    function previewRelease(
        Reward calldata reward,
        uint256[] calldata fulfilled
    ) external pure virtual returns (uint256[] memory payNow) {
        return _previewRelease(reward, fulfilled);
    }

    /**
     * @notice Shared implementation of the atomic reward curve.
     * @param reward The reward specification
     * @param fulfilled The core-verified per-leg delivered amounts (paired prefix)
     * @return payNow Per-leg uncapped reward amount, index-aligned with `reward.tokens`
     */
    function _previewRelease(
        Reward calldata reward,
        uint256[] calldata fulfilled
    ) internal pure returns (uint256[] memory payNow) {
        uint256 legCount = reward.tokens.length;
        uint256 fulfilledLen = fulfilled.length;

        payNow = new uint256[](legCount);

        for (uint256 j; j < legCount; ++j) {
            RewardToken calldata leg = reward.tokens[j];
            if (j < fulfilledLen) {
                payNow[j] = RewardMath.reward(fulfilled[j], leg.rate, leg.flat);
            } else {
                payNow[j] = leg.flat;
            }
        }
    }

    /**
     * @notice Builds the cross-chain proof message from this prover's destination fulfillment store
     * @dev Wire format: an 8-byte big-endian chain id header followed by, per hash, a 64-byte
     *      (intentHash, fulfillmentHash) pair. The fulfillmentHash is read from {_destFulfillment}; an
     *      unfulfilled intent reverts {IntentNotFulfilled}.
     * @param intentHashes Intent hashes to include in the message
     * @return encodedProofs The encoded proof message ready for dispatch
     */
    function _buildProofMessage(
        bytes32[] calldata intentHashes
    ) internal view returns (bytes memory encodedProofs) {
        uint256 size = intentHashes.length;

        // 8 bytes for chain ID + (32 bytes intent hash + 32 bytes fulfillmentHash) * size
        encodedProofs = new bytes(8 + size * 64);

        // Prepend chain ID to the encoded data
        uint64 chainId = CHAIN_ID;
        assembly {
            mstore(add(encodedProofs, 0x20), shl(192, chainId))
        }

        for (uint256 i = 0; i < size; ++i) {
            bytes32 intentHash = intentHashes[i];
            bytes32 fulfillmentBytes = _destFulfillment[intentHash];

            if (fulfillmentBytes == bytes32(0)) {
                revert IntentNotFulfilled(intentHash);
            }

            // Pack (intentHash, fulfillmentHash) after the 8-byte chain ID header
            assembly {
                let offset := add(8, mul(i, 64))
                mstore(add(add(encodedProofs, 0x20), offset), intentHash)
                mstore(
                    add(add(encodedProofs, 0x20), add(offset, 32)),
                    fulfillmentBytes
                )
            }
        }
    }

    /**
     * @notice Process intent proofs from a cross-chain message
     * @dev First-writer-wins on the fulfillment commitment. Unlike v2, there is no claimant validity
     *      check here — the second word of each pair is a `fulfillmentHash`, not a claimant. Claimant
     *      validity is checked once, at settle, against the supplied preimage.
     * @param data Encoded (intentHash, fulfillmentHash) pairs (without chain ID prefix)
     * @param destination Chain ID where the intent is being proven
     */
    function _processIntentProofs(
        bytes calldata data,
        uint64 destination
    ) internal {
        // If data is empty, just return early
        if (data.length == 0) return;

        // Ensure data length is multiple of 64 bytes (32 for hash + 32 for fulfillmentHash)
        if (data.length % 64 != 0) {
            revert ArrayLengthMismatch();
        }

        uint256 numPairs = data.length / 64;

        for (uint256 i = 0; i < numPairs; i++) {
            uint256 offset = i * 64;

            bytes32 intentHash = bytes32(data[offset:offset + 32]);
            bytes32 fulfillmentHash = bytes32(data[offset + 32:offset + 64]);

            // A zero fulfillmentHash is not a valid fact; skip defensively.
            if (fulfillmentHash == bytes32(0)) {
                continue;
            }

            // Skip rather than revert for already proven intents (first-writer-wins)
            if (_provenIntents[intentHash].fulfillmentHash != bytes32(0)) {
                emit IntentAlreadyProven(intentHash);
            } else {
                _provenIntents[intentHash] = ProofData({
                    destination: destination,
                    fulfillmentHash: fulfillmentHash
                });
                emit IntentProven(intentHash, destination, fulfillmentHash);
            }
        }
    }

    /**
     * @notice Challenge an intent proof if destination chain ID doesn't match
     * @dev Can be called by anyone to remove invalid proofs. Ensures intents are only claimable when
     *      executed on their intended destination chains.
     * @param destination The intended destination chain ID
     * @param routeHash The hash of the intent's route
     * @param rewardHash The hash of the reward specification
     */
    function challengeIntentProof(
        uint64 destination,
        bytes32 routeHash,
        bytes32 rewardHash
    ) external {
        bytes32 intentHash = keccak256(
            abi.encodePacked(destination, routeHash, rewardHash)
        );

        ProofData memory proof = _provenIntents[intentHash];

        // Only challenge if proof exists and destination chain ID doesn't match
        if (
            proof.fulfillmentHash != bytes32(0) &&
            proof.destination != destination
        ) {
            delete _provenIntents[intentHash];

            emit IntentProofInvalidated(intentHash);
        }
    }

    /**
     * @notice Checks if this contract supports a given interface
     * @dev Implements ERC165 interface detection
     * @param interfaceId Interface identifier to check
     * @return True if the interface is supported
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IPolicy).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
