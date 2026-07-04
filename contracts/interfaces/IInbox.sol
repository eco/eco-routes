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
     * @param intentHash Hash of the fulfilled intent
     * @param claimant Cross-VM compatible claimant identifier
     */
    event IntentFulfilled(bytes32 indexed intentHash, bytes32 indexed claimant);

    /**
     * @notice Emitted when an intent is proven
     * @dev Note that this event is emitted by both the Portal on the destination chain,
     * and the Prover on the source chain.
     * @param intentHash Hash of the proven intent
     * @param claimant Cross-VM compatible claimant identifier
     */
    event IntentProven(bytes32 indexed intentHash, bytes32 indexed claimant);

    /**
     * @notice Intent has already been fulfilled
     * @param intentHash Hash of the fulfilled intent
     */
    error IntentAlreadyFulfilled(bytes32 intentHash);

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
     * @notice Attempted to batch an unfulfilled intent
     * @param intentHash Hash of the unfulfilled intent
     */
    error IntentNotFulfilled(bytes32 intentHash);

    /**
     * @notice Chain ID is too large to fit in uint64
     * @param chainId The chain ID that is too large
     */
    error ChainIdTooLarge(uint256 chainId);

    /**
     * @notice Sent native amount is insufficient for the native `minTokens` leg the solver committed to
     * @param sent Amount of native tokens sent with the transaction
     * @param required Native input the solver committed to provide (the native `minTokens` leg's provided
     *        amount)
     */
    error InsufficientNativeAmount(uint256 sent, uint256 required);

    /**
     * @notice The solver provided less than the min-tokens floor for a token
     * @param token The min-tokens token (address(0) for native)
     * @param provided The amount the solver offered to provide for this leg
     * @param required The minimum input required by `route.minTokens`
     */
    error InsufficientTokens(
        address token,
        uint256 provided,
        uint256 required
    );

    /**
     * @notice `providedAmounts.length` does not match `route.minTokens.length`
     * @param provided The supplied `providedAmounts` length
     * @param expected The expected length (`route.minTokens.length`)
     */
    error ProvidedAmountsLengthMismatch(uint256 provided, uint256 expected);

    /**
     * @notice Fulfills an intent, recording the fulfillment into the named prover
     * @dev Validates intent hash, pulls the solver's provided input, executes calls, moves any unconsumed
     *      input to the intent's Account, and records the fulfillment into `prover`. The solver names the
     *      prover (policy) that will settle the reward.
     * @param intentHash The hash of the intent to fulfill
     * @param route Route information for the intent
     * @param rewardHash Hash of the reward details
     * @param claimant Cross-VM compatible claimant identifier
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `route.minTokens` (each
     *        `>= route.minTokens[j].amount`)
     * @param prover Prover (policy) to record the fulfillment into
     * @return Array of execution results
     */
    function fulfill(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        uint256[] memory providedAmounts,
        address prover
    ) external payable returns (bytes[] memory);

    /**
     * @notice Fulfills an intent and initiates proving in one transaction
     * @dev Validates intent hash, pulls the solver's provided input, executes calls, and marks fulfilled
     * @param intentHash The hash of the intent to fulfill
     * @param route Route information for the intent
     * @param rewardHash Hash of the reward details
     * @param claimant Cross-VM compatible claimant identifier
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `route.minTokens` (each
     *        `>= route.minTokens[j].amount`)
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
     *      - Polymer: Uses chainIDs
     *      - CCIP: Uses chain selectors that are totally separate from chainIDs
     *      You MUST consult the specific bridge provider's documentation to determine
     *      the correct domain ID for the source chain.
     */
    function fulfillAndProve(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        uint256[] memory providedAmounts,
        address prover,
        uint64 sourceChainDomainID,
        bytes memory data
    ) external payable returns (bytes[] memory);

    /**
     * @notice Initiates proving process for fulfilled intents
     * @dev Sends message to source chain to verify intent execution
     * @param prover Address of prover on the destination chain
     * @param sourceChainDomainID Domain ID of the source chain
     * @param intentHashes Array of intent hashes to prove
     * @param data Additional data for message formatting
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
        address prover,
        uint64 sourceChainDomainID,
        bytes32[] memory intentHashes,
        bytes memory data
    ) external payable;
}
