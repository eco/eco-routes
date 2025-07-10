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
     * @param claimant Address eligible to claim the intent rewards (as bytes32 for cross-VM compatibility)
     * @param destinationChainID Chain ID where the intent was proven
     */
    struct ProofData {
        bytes32 claimant;
        uint96 destinationChainID;
    }

    /**
     * @notice Arrays of intent hashes and claimants must have the same length
     */
    error ArrayLengthMismatch();

    /**
     * @notice Emitted when an intent is successfully proven
     * @param _hash Hash of the proven intent
     * @param _claimant Address eligible to claim the intent's rewards
     */
    event IntentProven(bytes32 indexed _hash, address indexed _claimant);

    /**
     * @notice Emitted when attempting to prove an already-proven intent
     * @dev Event instead of error to allow batch processing to continue
     * @param _intentHash Hash of the already proven intent
     */
    event IntentAlreadyProven(bytes32 _intentHash);

    /**
     * @notice Gets the proof mechanism type used by this prover
     * @return string indicating the prover's mechanism
     */
    function getProofType() external pure returns (string memory);

    /**
     * @notice Initiates the proving process for intents from the destination chain
     * @dev Implemented by specific prover mechanisms (storage, Hyperlane, Metalayer)
     * @param _sender Address of the original transaction sender
     * @param _sourceChainId Chain ID of the source chain
     * @param _intentHashes Array of intent hashes to prove
     * @param _claimants Array of claimant addresses
     * @param _data Additional data specific to the proving implementation
     */
    function prove(
        address _sender,
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        bytes32[] calldata _claimants,
        bytes calldata _data
    ) external payable;

    /**
     * @notice Returns the proof data for a given intent hash
     * @param _intentHash Hash of the intent to query
     * @return ProofData containing claimant and destination chain ID
     */
    function provenIntents(bytes32 _intentHash) external view returns (ProofData memory);
}
