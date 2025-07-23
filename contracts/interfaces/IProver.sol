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
     * @notice Initiates the proving process for intents from the destination chain
     * @dev Implemented by specific prover mechanisms (storage, Hyperlane, Metalayer)
     * @param sender Address of the original transaction sender
     * @param sourceChainId Chain ID of the source chain
     * @param encodedProofs Encoded (claimant, intentHash) pairs as bytes
     * @param data Additional data specific to the proving implementation
     */
    function prove(
        address sender,
        uint256 sourceChainId,
        bytes calldata encodedProofs,
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
