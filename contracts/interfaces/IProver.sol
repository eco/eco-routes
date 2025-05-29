// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISemver} from "./ISemver.sol";
import {Intent} from "../types/Intent.sol";

/**
 * @title IProver
 * @notice Interface for proving intent fulfillment
 * @dev Defines required functionality for proving intent execution with different
 * proof mechanisms (storage or Hyperlane)
 */
interface IProver is ISemver {
    struct ProofData {
        uint96 destinationChainID;
        address claimant;
    }

    /**
     * @notice Arrays of intent hashes and claimants must have the same length
     */
    error ArrayLengthMismatch();

    /**
     * @notice Destination chain ID associated with intent does not match that in proof.
     * @param _hash Hash of the intent
     * @param _expectedDestinationChainID Expected destination chain ID for the intent
     * @param _actualDestinationChainID Actual destination chain ID for the intent
     */
    error BadDestinationChainID(
        bytes32 _hash,
        uint96 _expectedDestinationChainID,
        uint96 _actualDestinationChainID
    );

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
     * @notice Fetches a ProofData from the provenIntents mapping
     * @param _intentHash the hash of the intent whose proof data is being queried
     * @return ProofData struct containing the destination chain ID and claimant address
     */
    function provenIntents(
        bytes32 _intentHash
    ) external view returns (ProofData memory);

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
        address[] calldata _claimants,
        bytes calldata _data
    ) external payable;

    /**
     * @notice Challenges a recorded proof
     * @param _intent Intent to challenge
     * @dev Clears the proof if the destination chain ID in the intent does not match the one in the proof
     * @dev even if not challenged, an incorrect proof cannot be used to claim rewards.
     * @dev does nothing if chainID is correct
     */
    function challengeIntentProof(Intent calldata _intent) external;

    /**
     * @notice Pre-sets the destinationChainID associated with an intentHash
     * @param _intentHash The hash of the intent
     * @param _destinationChainID The destination chain ID of the intent
     */
    function prepProof(
        bytes32 _intentHash,
        uint96 _destinationChainID
    ) external;
}
