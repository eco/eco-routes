// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IProver} from "../interfaces/IProver.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";

/**
 * @title BaseProver
 * @notice Base implementation for intent proving contracts
 * @dev Provides core storage and functionality for tracking proven intents
 * and their claimants
 */
abstract contract BaseProver is IProver, ERC165 {
    using AddressConverter for bytes32;
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
     * @dev Empty struct (zero claimant) indicates intent hasn't been proven
     */
    mapping(bytes32 => ProofData) internal _provenIntents;

    /**
     * @notice DESTINATION fulfillment store: intent hash to the recorded claimant
     * @dev Written by {recordFulfillment} (only the local Portal). Zero means the intent has not
     *      been fulfilled on this chain under this prover. This is the storage that moved out of
     *      the Inbox: the prover now owns the destination fulfillment fact and builds its own
     *      cross-chain proof message from it. One slot per intent — a second fulfillment reverts.
     */
    mapping(bytes32 => bytes32) internal _destFulfillment;

    /**
     * @notice Get proof data for an intent
     * @param intentHash The intent hash to query
     * @return ProofData struct containing claimant and destination
     */
    function provenIntents(
        bytes32 intentHash
    ) external view returns (ProofData memory) {
        return _provenIntents[intentHash];
    }

    /**
     * @notice Get the destination fulfillment claimant recorded for an intent on this chain
     * @dev The fulfillment fact that moved out of the Inbox into the prover. Zero means the intent
     *      has not been fulfilled on this chain under this prover. This reads the destination store
     *      ({recordFulfillment}), distinct from {provenIntents} which reads the cross-chain proof store.
     * @param intentHash The intent hash to query
     * @return The recorded claimant identifier (bytes32), or zero if unfulfilled
     */
    function destFulfillment(
        bytes32 intentHash
    ) external view returns (bytes32) {
        return _destFulfillment[intentHash];
    }

    /**
     * @notice Initializes the BaseProver contract
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
     * @dev Only the local Portal may call this — it is the trusted destination fulfillment source
     *      (it re-derived the intent hash and executed the route). Enforces a one-shot gate: a
     *      second fulfillment of the same intent reverts {IntentAlreadyFulfilled}. The `destination`
     *      argument is the local chain id supplied by the Portal; it is implied by {CHAIN_ID} at
     *      proof-build time, so it is not stored here.
     * @param intentHash Hash of the fulfilled intent
     * @param claimant Cross-VM compatible claimant identifier eligible for the reward
     */
    function recordFulfillment(
        bytes32 intentHash,
        uint64 /* destination */,
        bytes32 claimant
    ) external virtual {
        if (msg.sender != PORTAL) {
            revert NotPortal(msg.sender);
        }
        if (_destFulfillment[intentHash] != bytes32(0)) {
            revert IntentAlreadyFulfilled(intentHash);
        }
        _destFulfillment[intentHash] = claimant;
    }

    /**
     * @notice Builds the cross-chain proof message from this prover's destination fulfillment store
     * @dev Replicates the wire format the Inbox previously produced: an 8-byte big-endian chain id
     *      header followed by, per hash, a 64-byte (intentHash, claimant) pair. The claimant is read
     *      from {_destFulfillment}; an unfulfilled intent reverts {IntentNotFulfilled}.
     * @param intentHashes Intent hashes to include in the message
     * @return encodedProofs The encoded proof message ready for dispatch
     */
    function _buildProofMessage(
        bytes32[] calldata intentHashes
    ) internal view returns (bytes memory encodedProofs) {
        uint256 size = intentHashes.length;

        // 8 bytes for chain ID + (32 bytes intent hash + 32 bytes claimant) * size
        encodedProofs = new bytes(8 + size * 64);

        // Prepend chain ID to the encoded data
        uint64 chainId = CHAIN_ID;
        assembly {
            mstore(add(encodedProofs, 0x20), shl(192, chainId))
        }

        for (uint256 i = 0; i < size; ++i) {
            bytes32 intentHash = intentHashes[i];
            bytes32 claimantBytes = _destFulfillment[intentHash];

            if (claimantBytes == bytes32(0)) {
                revert IntentNotFulfilled(intentHash);
            }

            // Pack (intentHash, claimant) after the 8-byte chain ID header
            assembly {
                let offset := add(8, mul(i, 64))
                mstore(add(add(encodedProofs, 0x20), offset), intentHash)
                mstore(
                    add(add(encodedProofs, 0x20), add(offset, 32)),
                    claimantBytes
                )
            }
        }
    }

    /**
     * @notice Process intent proofs from a cross-chain message
     * @param data Encoded (intentHash, claimant) pairs (without chain ID prefix)
     * @param destination Chain ID where the intent is being proven
     */
    function _processIntentProofs(
        bytes calldata data,
        uint64 destination
    ) internal {
        // If data is empty, just return early
        if (data.length == 0) return;

        // Ensure data length is multiple of 64 bytes (32 for hash + 32 for claimant)
        if (data.length % 64 != 0) {
            revert ArrayLengthMismatch();
        }

        uint256 numPairs = data.length / 64;

        for (uint256 i = 0; i < numPairs; i++) {
            uint256 offset = i * 64;

            // Extract intentHash and claimant using slice
            bytes32 intentHash = bytes32(data[offset:offset + 32]);
            bytes32 claimantBytes = bytes32(data[offset + 32:offset + 64]);

            // Check if the claimant bytes32 represents a valid Ethereum address
            if (!claimantBytes.isValidAddress()) {
                // Skip non-EVM addresses that can't be converted
                continue;
            }

            address claimant = claimantBytes.toAddress();

            // Validate claimant is not zero address
            if (claimant == address(0)) {
                continue; // Skip invalid claimants
            }

            // Skip rather than revert for already proven intents
            if (_provenIntents[intentHash].claimant != address(0)) {
                emit IntentAlreadyProven(intentHash);
            } else {
                _provenIntents[intentHash] = ProofData({
                    claimant: claimant,
                    destination: destination
                });
                emit IntentProven(intentHash, claimant, destination);
            }
        }
    }

    /**
     * @notice Challenge an intent proof if destination chain ID doesn't match
     * @dev Can be called by anyone to remove invalid proofs. This is a safety mechanism to ensure
     *      intents are only claimable when executed on their intended destination chains.
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
        if (proof.claimant != address(0) && proof.destination != destination) {
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
            interfaceId == type(IProver).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
