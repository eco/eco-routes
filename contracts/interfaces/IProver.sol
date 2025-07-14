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
     * @param destinationChainID Chain ID where the intent was proven
     */
    struct ProofData {
        address claimant;
        uint64 destinationChainID;
    }

    /**
     * @notice Arrays of intent hashes and claimants must have the same length
     */
    error ArrayLengthMismatch();

    /**
     * @notice Emitted when an intent is successfully proven
     * @param hash Hash of the proven intent
     * @param claimant Address eligible to claim the intent's rewards
     */
    event IntentProven(bytes32 indexed hash, address indexed claimant);

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
     * @param intentHashes Array of intent hashes to prove
     * @param claimants Array of claimant addresses (as bytes32 for cross-chain compatibility)
     * @param data Additional data specific to the proving implementation
     */
    function prove(
        address sender,
        uint256 sourceChainId,
        bytes32[] calldata intentHashes,
        bytes32[] calldata claimants,
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
}
