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
     * @notice Emitted when an intent is proven
     * @dev Note that this event is emitted by both the Portal on the destination chain,
     * and the Prover on the source chain.
     * @param intentHash Hash of the proven intent
     * @param claimant Cross-VM compatible claimant identifier
     */
    event IntentProven(
        bytes32 indexed intentHash,
        bytes32 indexed claimant
    );

    /**
     * @notice Thrown when an attempt is made to fulfill an intent on the wrong destination chain
     * @param chainID Chain ID of the destination chain on which this intent should be fulfilled
     */
    error WrongChain(uint64 chainID);

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
     * @notice Chain ID is too large to fit in uint64
     * @param chainId The chain ID that is too large
     */
    error InboxChainIdTooLarge(uint256 chainId);

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
     * @param sourceChainDomainID Domain ID of the source chain where the intent was created
     * @param data Additional data for message formatting
     * @return Array of execution results
     * 
     * @dev WARNING: sourceChainDomainID is NOT necessarily the same as chain ID.
     *      Each bridge provider uses their own domain ID mapping system:
     *      - Hyperlane: Uses custom domain IDs that may differ from chain IDs
     *      - LayerZero: Uses endpoint IDs that map to chains differently
     *      - Metalayer: Uses domain IDs specific to their routing system
     *      You MUST consult the specific bridge provider's documentation to determine
     *      the correct domain ID for the source chain.
     */
    function fulfillAndProve(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        address prover,
        uint64 sourceChainDomainID,
        bytes memory data
    ) external payable returns (bytes[] memory);

    /**
     * @notice Initiates proving process for fulfilled intents
     * @dev Sends message to source chain to verify intent execution
     * @param sourceChainDomainID Domain ID of the source chain
     * @param prover Address of prover on the destination chain
     * @param intentHashes Array of intent hashes to prove
     * @param data Additional data for message formatting
     * 
     * @dev WARNING: sourceChainDomainID is NOT necessarily the same as chain ID.
     *      Each bridge provider uses their own domain ID mapping system:
     *      - Hyperlane: Uses custom domain IDs that may differ from chain IDs
     *      - LayerZero: Uses endpoint IDs that map to chains differently
     *      - Metalayer: Uses domain IDs specific to their routing system
     *      You MUST consult the specific bridge provider's documentation to determine
     *      the correct domain ID for the source chain.
     */
    function prove(
        uint64 sourceChainDomainID,
        address prover,
        bytes32[] memory intentHashes,
        bytes memory data
    ) external payable;
}
