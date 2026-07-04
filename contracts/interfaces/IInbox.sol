// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Route, Reward} from "../types/Intent.sol";

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
     * @notice Zero claimant identifier provided
     */
    error ZeroClaimant();

    /**
     * @notice A fulfill was attempted on a chain whose id is not the intent's committed `destination`
     * @param current The current chain id (block.chainid)
     * @param expected The intent's committed destination chain id
     */
    error WrongDestinationChain(uint64 current, uint64 expected);

    /**
     * @notice The runtime consumed reward escrow reserved in a (same-chain collapsed) execution Account
     * @dev Reward-conservation postcondition: a reward-leg token's Account balance dropped below its
     *      pre-execution snapshot. Reverts the whole fulfill (griefing DoS at worst, never reward theft).
     * @param token The reward-leg token whose escrow was touched
     * @param live The reward-leg token balance after execution
     * @param reserved The reserved escrow snapshot taken before staging solver input
     */
    error RewardEscrowTouched(address token, uint256 live, uint256 reserved);

    /**
     * @notice The destination-side {executeAsOwner} was called for a source-chain (or same-chain) intent
     * @dev CROSS-CHAIN ONLY: when `source == block.chainid` the `block.chainid`-keyed Account is (or
     *      collapses with) the SOURCE escrow Account, which must be governed by the reward-aware
     *      {IIntentSource-executeAsOwner}, not this reward-blind path.
     * @param source The intent's committed source chain id (equal to block.chainid)
     */
    error SourceChainOwnerOnly(uint64 source);

    /**
     * @notice Attempted to batch an unfulfilled intent
     * @param intentHash Hash of the unfulfilled intent
     */
    error IntentNotFulfilled(bytes32 intentHash);

    /**
     * @notice The intent has NOTHING to fulfill — both `Route.minTokens` and `Reward.tokens` are empty.
     * @dev Such an intent asks a solver to deliver nothing for no reward, so no honest fulfill exists; the
     *      only legitimate way to run its committed `runtime(payload)` is the owner-gated
     *      {IIntentSource-executeAsOwner}. Rejecting it in {IInbox-fulfill} closes the deposit-address
     *      griefing vector (H2): a third party front-runs an owner-cook (empty-reward, empty-minTokens)
     *      intent to record a permanent fulfillment on the prover, which would lock the Account against
     *      re-fulfill/refund/executeAsOwner — bricking a REUSABLE deposit address for every later deposit.
     */
    error NothingToFulfill();

    /**
     * @notice Chain ID is too large to fit in uint64
     * @param chainId The chain ID that is too large
     */
    error ChainIdTooLarge(uint256 chainId);

    /**
     * @notice {executeAsOwner} was called by someone other than the route keeper
     * @param caller The unauthorized caller
     */
    error NotAccountKeeper(address caller);

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
     * @dev Derives the intent hash from `(source, destination, route, reward)`, requires
     *      `destination == block.chainid`, stages the solver's provided input onto the DESTINATION
     *      Account, executes `route.runtime(payload)` in it, enforces reward-conservation, and records the
     *      fulfillment into `prover`. The solver names the prover (policy) that will settle the reward.
     * @param source Origin chain ID committed in the intent hash
     * @param destination Destination chain ID committed in the intent hash (must equal block.chainid)
     * @param route Route information for the intent
     * @param reward Reward details of the intent (legs authenticated by the derived intent hash)
     * @param claimant Cross-VM compatible claimant identifier
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `route.minTokens` (each
     *        `>= route.minTokens[j].amount`)
     * @param prover Prover (policy) to record the fulfillment into
     * @return The runtime's raw return data
     */
    function fulfill(
        uint64 source,
        uint64 destination,
        Route memory route,
        Reward memory reward,
        bytes32 claimant,
        uint256[] memory providedAmounts,
        address prover
    ) external payable returns (bytes memory);

    /**
     * @notice Fulfills an intent and initiates proving in one transaction
     * @dev Validates intent hash, executes the route, and records the fulfillment
     * @param source Origin chain ID committed in the intent hash
     * @param destination Destination chain ID committed in the intent hash (must equal block.chainid)
     * @param route Route information for the intent
     * @param reward Reward details of the intent (legs authenticated by the derived intent hash)
     * @param claimant Cross-VM compatible claimant identifier
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `route.minTokens` (each
     *        `>= route.minTokens[j].amount`)
     * @param prover Address of prover on the destination chain
     * @param sourceChainDomainID Domain ID of the source chain where the intent was created
     * @param data Additional data for message formatting
     * @return The runtime's raw return data
     *
     * @dev WARNING: sourceChainDomainID is NOT necessarily the same as chain ID (nor the same as
     *      `source`): `source` is the origin CHAIN ID committed in the hash, while sourceChainDomainID
     *      is the bridge transport's domain id used to route the proof back.
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
        uint64 source,
        uint64 destination,
        Route memory route,
        Reward memory reward,
        bytes32 claimant,
        uint256[] memory providedAmounts,
        address prover,
        uint64 sourceChainDomainID,
        bytes memory data
    ) external payable returns (bytes memory);

    /**
     * @notice Owner-cook on the DESTINATION side: `route.keeper` runs an arbitrary runtime against the
     *         intent's DESTINATION (execution) Account via delegatecall
     * @dev Only `route.keeper` may call. Operates the destination execution Account (keyed by this chain
     *      id) — the one holding any unconsumed solver input — never the source escrow Account. This is
     *      the destination leftover-retrieval / stray-fund rescue (the core is unopinionated — there is no
     *      `recipient` / auto-sweep).
     * @param source Origin chain ID committed in the intent hash
     * @param route The route of the intent (supplies `route.keeper` + `route.portal`)
     * @param rewardHash The hash of the reward details (opaque on the destination)
     * @param runtime The delegatecall target to run against the Account
     * @param payload The opaque program forwarded to `runtime`
     * @return The runtime's raw return data
     */
    function executeAsOwner(
        uint64 source,
        Route memory route,
        bytes32 rewardHash,
        address runtime,
        bytes calldata payload
    ) external payable returns (bytes memory);

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
