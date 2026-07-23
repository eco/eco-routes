// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISemver} from "./ISemver.sol";

/**
 * @title IProver
 * @notice Interface for proving intent fulfillment
 * @dev Defines required functionality for proving intent execution with different
 * proof mechanisms (storage or Hyperlane)
 */
interface IProver is ISemver {
    /**
     * @notice Proof data stored for each proven intent
     * @param claimant Address eligible to claim the intent rewards
     * @param destination Chain ID where the intent was proven
     */
    struct ProofData {
        address claimant;
        uint64 destination;
    }

    /**
     * @notice Arrays of intent hashes and claimants must have the same length
     */
    error ArrayLengthMismatch();

    /**
     * @notice Portal address cannot be zero
     */
    error ZeroPortal();

    /**
     * @notice Chain ID is too large to fit in uint64
     * @param chainId The chain ID that is too large
     */
    error ChainIdTooLarge(uint256 chainId);

    /**
     * @notice Only the local Portal may record a destination fulfillment
     * @param caller Address that attempted to call {recordFulfillment}
     */
    error NotPortal(address caller);

    /**
     * @notice The intent has already been fulfilled on this chain under this prover
     * @dev Enforces the one-shot destination fulfillment gate in {recordFulfillment}
     * @param intentHash Hash of the already-fulfilled intent
     */
    error IntentAlreadyFulfilled(bytes32 intentHash);

    /**
     * @notice The intent has no recorded destination fulfillment under this prover
     * @dev Raised by the proof-message builder when asked to prove an unfulfilled intent
     * @param intentHash Hash of the unfulfilled intent
     */
    error IntentNotFulfilled(bytes32 intentHash);

    /**
     * @notice Emitted when an intent is successfully proven
     * @dev Emitted by the Prover on the source chain.
     * @param intentHash Hash of the proven intent
     * @param claimant Address eligible to claim the intent rewards
     * @param destination Destination chain ID where the intent was proven
     */
    event IntentProven(
        bytes32 indexed intentHash,
        address indexed claimant,
        uint64 destination
    );

    /**
     * @notice Emitted when an intent proof is invalidated
     * @param intentHash Hash of the invalidated intent
     */
    event IntentProofInvalidated(bytes32 indexed intentHash);

    /**
     * @notice Emitted when attempting to prove an already-proven intent
     * @dev Event instead of error to allow batch processing to continue
     * @param intentHash Hash of the already proven intent
     */
    event IntentAlreadyProven(bytes32 intentHash);

    /**
     * @notice Gets the proof mechanism type used by this prover
     * @return string indicating the prover's mechanism
     */
    function getProofType() external pure returns (string memory);

    /**
     * @notice Records a destination-chain fulfillment for an intent
     * @dev Called by the local Portal/Inbox after a successful {IInbox-fulfill}. The prover
     *      is the owner of destination fulfillment storage: it records the claimant here and
     *      later builds the cross-chain proof message from its own store. Enforces a one-shot
     *      gate (a second fulfillment of the same intent reverts {IntentAlreadyFulfilled}).
     *      Only the Portal may call this ({NotPortal} otherwise).
     * @param intentHash Hash of the fulfilled intent
     * @param destination Chain ID on which the fulfillment occurred (the local chain)
     * @param claimant Cross-VM compatible claimant identifier eligible for the reward
     */
    function recordFulfillment(
        bytes32 intentHash,
        uint64 destination,
        bytes32 claimant
    ) external;

    /**
     * @notice Initiates the proving process for intents from the destination chain
     * @dev Implemented by specific prover mechanisms (storage, Hyperlane, Metalayer). The prover
     *      builds the cross-chain proof message from its own destination fulfillment store, so the
     *      caller supplies only the intent hashes to prove (each must have been recorded via
     *      {recordFulfillment}).
     * @param sender Address of the original transaction sender
     * @param sourceChainDomainID Domain ID of the source chain
     * @param intentHashes Intent hashes to prove; the (intentHash, claimant) wire pairs are read
     *        from this prover's destination fulfillment store
     * @param data Additional data specific to the proving implementation
     *
     * @dev WARNING: sourceChainDomainID is NOT necessarily the same as chain ID.
     *      Each bridge provider uses their own domain ID mapping system:
     *      - Hyperlane: Uses custom domain IDs that may differ from chain IDs
     *      - LayerZero: Uses endpoint IDs that map to chains differently
     *      - Metalayer: Uses domain IDs specific to their routing system
     *      - Polymer: Uses chainIDs
     *      - CCIP: Uses chain selectors that are totally separate from chainIDs
     *      You MUST consult the specific bridge provider's documentation to determine
     *      the correct domain ID for the source chain.
     */
    function prove(
        address sender,
        uint64 sourceChainDomainID,
        bytes32[] calldata intentHashes,
        bytes calldata data
    ) external payable;

    /**
     * @notice Returns the proof data for a given intent hash
     * @param intentHash Hash of the intent to query
     * @return ProofData containing claimant and destination chain ID
     */
    function provenIntents(
        bytes32 intentHash
    ) external view returns (ProofData memory);

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
    ) external;
}
