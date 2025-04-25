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
}
