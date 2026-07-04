// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISemver} from "./ISemver.sol";
import {Reward} from "../types/Intent.sol";

/**
 * @title IPolicy
 * @notice Interface for proving intent fulfillment and computing the reward release (v3 hash-only model)
 * @dev The prover is the settlement policy on both chains. It records the destination fulfillment as a
 *      HASH-ONLY fact — only `(intentHash, fulfillmentHash)` crosses chains, where
 *      `fulfillmentHash = keccak256(abi.encode(intentHash, claimant, fulfilled))`. The `(claimant,
 *      fulfilled[])` preimage is supplied as calldata at `settle` and verified against the proven hash;
 *      the claimant is NOT stored in the fact. The prover also exposes {previewRelease}, a pure view the
 *      Account consults to turn the verified `fulfilled[]` into per-leg reward amounts.
 */
interface IPolicy is ISemver {
    /**
     * @notice Proof data stored for each proven intent
     * @dev The claimant and per-leg amounts are NOT stored here — only their commitment
     *      (`fulfillmentHash`) crosses chains. A zero `fulfillmentHash` means no proof was recorded.
     * @param destination Chain ID where the intent was proven
     * @param fulfillmentHash Commitment to the proven `(intentHash, claimant, fulfilled[])` tuple
     */
    struct ProofData {
        uint64 destination;
        bytes32 fulfillmentHash;
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
     * @param destination Destination chain ID where the intent was proven
     * @param fulfillmentHash Commitment to the proven `(intentHash, claimant, fulfilled[])` tuple
     */
    event IntentProven(
        bytes32 indexed intentHash,
        uint64 indexed destination,
        bytes32 fulfillmentHash
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
     * @dev Called by the local Portal/Inbox after a successful {IInbox-fulfill}. Stores the hash-only
     *      fulfillment fact (`fulfillmentHash`) and later builds the cross-chain proof message from its
     *      own store. Enforces a one-shot gate ({IntentAlreadyFulfilled}). Only the Portal may call this
     *      ({NotPortal} otherwise).
     * @param intentHash Hash of the fulfilled intent
     * @param destination Chain ID on which the fulfillment occurred (the local chain)
     * @param fulfillmentHash Commitment to the proven `(intentHash, claimant, fulfilled[])` tuple
     */
    function recordFulfillment(
        bytes32 intentHash,
        uint64 destination,
        bytes32 fulfillmentHash
    ) external;

    /**
     * @notice Initiates the proving process for intents from the destination chain
     * @dev The prover builds the cross-chain proof message from its own destination fulfillment store,
     *      so the caller supplies only the intent hashes to prove (each must have been recorded via
     *      {recordFulfillment}). The wire pairs are `(intentHash, fulfillmentHash)`.
     * @param sender Address of the original transaction sender
     * @param sourceChainDomainID Domain ID of the source chain
     * @param intentHashes Intent hashes to prove; the (intentHash, fulfillmentHash) wire pairs are read
     *        from this prover's destination fulfillment store
     * @param data Additional data specific to the proving implementation
     *
     * @dev WARNING: sourceChainDomainID is NOT necessarily the same as chain ID.
     *      Each bridge provider uses their own domain ID mapping system.
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
     * @return ProofData containing destination chain ID and the fulfillment commitment
     */
    function provenIntents(
        bytes32 intentHash
    ) external view returns (ProofData memory);

    /**
     * @notice Computes the per-leg reward amounts owed for a set of delivered amounts (pure view)
     * @dev The Account consults this (as a staticcall/view — no reentrancy surface) at settle to turn the
     *      core-verified `fulfilled[]` into amounts. PAIRED legs (`j < fulfilled.length`) return
     *      `fulfilled[j] * rate / WAD + flat`; EXTRA legs (`j >= fulfilled.length`) return `flat`. The
     *      result is index-aligned with `reward.tokens`; the Account caps each entry at its own balance.
     * @param reward The reward specification (its `tokens` legs define the curve)
     * @param fulfilled The core-verified per-leg delivered amounts (paired prefix)
     * @return payNow Per-leg uncapped reward amount, index-aligned with `reward.tokens`
     */
    function previewRelease(
        Reward calldata reward,
        uint256[] calldata fulfilled
    ) external view returns (uint256[] memory payNow);

    /**
     * @notice Challenge an intent proof if destination chain ID doesn't match
     * @dev Can be called by anyone to remove invalid proofs. Safety mechanism ensuring intents are only
     *      claimable when executed on their intended destination chains.
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
