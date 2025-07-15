// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Route} from "../types/Intent.sol";

/**
 * @title IInbox
 * @notice Interface for the destination chain portion of the Eco Protocol's intent system
 * @dev Handles intent fulfillment and proving via different mechanisms (storage proofs,
 * Hyperlane instant/batched)
 */
interface IInbox {
    /**
     * @notice Emitted when an intent is successfully fulfilled
     * @param hash Hash of the fulfilled intent
     * @param claimant Cross-VM compatible claimant identifier
     */
    event IntentFulfilled(bytes32 indexed hash, bytes32 indexed claimant);

    /**
     * @notice Thrown when an attempt is made to fulfill an intent on the wrong destination chain
     * @param chainID Chain ID of the destination chain on which this intent should be fulfilled
     */
    error WrongChain(uint256 chainID);

    /**
     * @notice Intent has already been fulfilled
     * @param hash Hash of the fulfilled intent
     */
    error IntentAlreadyFulfilled(bytes32 hash);

    /**
     * @notice Invalid portal address provided
     * @param portal Address that is not a valid portal
     */
    error InvalidPortal(address portal);

    /**
     * @notice Intent has expired and can no longer be fulfilled
     */
    error IntentExpired();

    /**
     * @notice Generated hash doesn't match expected hash
     * @param expectedHash Hash that was expected
     */
    error InvalidHash(bytes32 expectedHash);

    /**
     * @notice Zero claimant identifier provided
     */
    error ZeroClaimant();

    /**
     * @notice Call during intent execution failed
     * @param addr Target contract address
     * @param data Call data that failed
     * @param value Native token value sent
     * @param returnData Error data returned
     */
    error IntentCallFailed(
        address addr,
        bytes data,
        uint256 value,
        bytes returnData
    );

    /**
     * @notice Attempted call to a destination-chain prover
     */
    error CallToProver();

    /**
     * @notice Attempted call to an EOA
     * @param eoa EOA address to which call was attempted
     */
    error CallToEOA(address eoa);

    /**
     * @notice Attempted to batch an unfulfilled intent
     * @param hash Hash of the unfulfilled intent
     */
    error IntentNotFulfilled(bytes32 hash);

    /**
     * @notice Fulfills an intent using storage proofs
     * @dev Validates intent hash, executes calls, and marks as fulfilled
     * @param intentHash The hash of the intent to fulfill
     * @param route Route information for the intent
     * @param rewardHash Hash of the reward details
     * @param claimant Cross-VM compatible claimant identifier
     * @return Array of execution results
     */
    function fulfill(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant
    ) external payable returns (bytes[] memory);

    /**
     * @notice Fulfills an intent and initiates proving in one transaction
     * @dev Validates intent hash, executes calls, and marks as fulfilled
     * @param intentHash The hash of the intent to fulfill
     * @param route Route information for the intent
     * @param rewardHash Hash of the reward details
     * @param claimant Cross-VM compatible claimant identifier
     * @param prover Address of prover on the destination chain
     * @param source The source chain ID where the intent was created
     * @param data Additional data for message formatting
     * @return Array of execution results
     */
    function fulfillAndProve(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        address prover,
        uint64 source,
        bytes memory data
    ) external payable returns (bytes[] memory);

    /**
     * @notice Initiates proving process for fulfilled intents
     * @dev Sends message to source chain to verify intent execution
     * @param source Chain ID of the source chain
     * @param prover Address of prover on the destination chain
     * @param intentHashes Array of intent hashes to prove
     * @param data Additional data for message formatting
     */
    function prove(
        uint256 source,
        address prover,
        bytes32[] memory intentHashes,
        bytes memory data
    ) external payable;
}
