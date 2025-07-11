// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISemver} from "./ISemver.sol";

import {Route} from "../types/UniversalIntent.sol";

/**
 * @title IInbox
 * @notice Interface for the destination chain portion of the Eco Protocol's intent system
 * @dev Handles intent fulfillment and proving via different mechanisms (storage proofs,
 * Hyperlane instant/batched)
 */
interface IInbox is ISemver {
    /**
     * @notice Emitted when an intent is successfully fulfilled
     * @param _hash Hash of the fulfilled intent
     * @param _sourceChainID ID of the source chain
     * @param _prover Address of the prover that fulfilled the intent
     * @param _claimant Cross-VM compatible claimant identifier
     */
    event Fulfillment(
        bytes32 indexed _hash,
        uint256 indexed _sourceChainID,
        bytes32 indexed _prover,
        bytes32 _claimant
    );

    /**
     * @notice Thrown when an attempt is made to fulfill an intent on the wrong destination chain
     * @param _chainID Chain ID of the destination chain on which this intent should be fulfilled
     */
    error WrongChain(uint256 _chainID);

    /**
     * @notice Intent has already been fulfilled
     * @param _hash Hash of the fulfilled intent
     */
    error IntentAlreadyFulfilled(bytes32 _hash);

    /**
     * @notice Invalid portal address provided
     * @param _portal Address that is not a valid portal
     */
    error InvalidPortal(address _portal);

    /**
     * @notice Intent has expired and can no longer be fulfilled
     */
    error IntentExpired();

    /**
     * @notice Generated hash doesn't match expected hash
     * @param _expectedHash Hash that was expected
     */
    error InvalidHash(bytes32 _expectedHash);

    /**
     * @notice Zero claimant identifier provided
     */
    error ZeroClaimant();

    /**
     * @notice Call during intent execution failed
     * @param _addr Target contract address
     * @param _data Call data that failed
     * @param value Native token value sent
     * @param _returnData Error data returned
     */
    error IntentCallFailed(
        address _addr,
        bytes _data,
        uint256 value,
        bytes _returnData
    );

    /**
     * @notice Attempted call to a destination-chain prover
     */
    error CallToProver();

    /**
     * @notice Attempted call to an EOA
     * @param _EOA EOA address to which call was attempted
     */
    error CallToEOA(address _EOA);

    /**
     * @notice Attempted to batch an unfulfilled intent
     * @param _hash Hash of the unfulfilled intent
     */
    error IntentNotFulfilled(bytes32 _hash);

    /**
     * @notice Fulfills an intent using storage proofs
     * @dev Validates intent hash, executes calls, and marks as fulfilled
     * @param _sourceChainId The source chain ID where the intent was created
     * @param _route Route information for the intent
     * @param _rewardHash Hash of the reward details
     * @param _claimant Cross-VM compatible claimant identifier
     * @param _expectedHash Expected hash for validation
     * @param _localProver The prover contract to use for verification
     * @return Array of execution results
     */
    function fulfill(
        uint64 _sourceChainId,
        Route memory _route,
        bytes32 _rewardHash,
        bytes32 _claimant,
        bytes32 _expectedHash,
        address _localProver
    ) external payable returns (bytes[] memory);

    /**
     * @notice Fulfills an intent using storage proofs
     * @dev Validates intent hash, executes calls, and marks as fulfilled
     * @param _sourceChainId The source chain ID where the intent was created
     * @param _route Route information for the intent
     * @param _rewardHash Hash of the reward details
     * @param _claimant Cross-VM compatible claimant identifier
     * @param _expectedHash Expected hash for validation
     * @param _localProver Address of prover on the destination chain
     * @param _data Additional data for message formatting
     * @return Array of execution results
     */
    function fulfillAndProve(
        uint64 _sourceChainId,
        Route memory _route,
        bytes32 _rewardHash,
        bytes32 _claimant,
        bytes32 _expectedHash,
        address _localProver,
        bytes memory _data
    ) external payable returns (bytes[] memory);

    /**
     * @notice Initiates proving process for fulfilled intents
     * @dev Sends message to source chain to verify intent execution
     * @param _sourceChainId Chain ID of the source chain
     * @param _intentHashes Array of intent hashes to prove
     * @param _localProver Address of prover on the destination chain
     * @param _data Additional data for message formatting
     */
    function initiateProving(
        uint256 _sourceChainId,
        bytes32[] memory _intentHashes,
        address _localProver,
        bytes memory _data
    ) external payable;
}
