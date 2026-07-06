// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IStreamingPolicy} from "./IStreamingPolicy.sol";
import {Route, Reward} from "../types/Intent.sol";

/**
 * @title IStreamingFlashPolicy
 * @notice Interface for the STANDING-POOL zero-capital same-chain flash policy.
 * @dev A pool intent escrows a replenishable reward budget (its reward legs ARE the pool) and is
 *      fulfilled in successive flash SLICES: each {flashSlice} advances the ENTIRE pool to the policy via
 *      {IIntentSource-settleStream} (a session-scoped {IStreamingPolicy-consumeStreamClaims}), stages the
 *      rate-derived slice back as the route input, executes, and forwards the remainder as the solver's
 *      margin. The intent stays `Funded` between slices; {flashSlice} is the ONLY fulfillment path (a
 *      plain fulfill reverts at {IPolicy-recordFulfillment}), and {IIntentSource-closeStream} is the
 *      keeper's native exit.
 */
interface IStreamingFlashPolicy is IStreamingPolicy {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The claimant is zero, the policy itself, or not a valid EVM address.
    error InvalidClaimant();

    /// @notice The intent's `reward.prover` does not name this policy.
    error InvalidProver();

    /// @notice A native transfer that must succeed (the advance hand-off to the solver) failed.
    error NativeTransferFailed();

    /**
     * @notice A session-gated entry ({IPolicy-recordFulfillment} / {consumeStreamClaims}) was reached with
     *         no open flash session for the intent — e.g. a plain fulfill against a pool intent.
     * @param intentHash Hash the call was attempted for.
     */
    error NotFlashSession(bytes32 intentHash);

    /**
     * @notice The open session's advance was already consumed (a second {consumeStreamClaims} inside one
     *         session — the consume-once double-release guard).
     * @param intentHash Hash of the session intent.
     */
    error AdvanceAlreadyConsumed(bytes32 intentHash);

    /**
     * @notice A fulfillment record arrived during a flash session that is not the session's expected
     *         real-claimant fact (wrong claimant or wrong slice amounts).
     * @param intentHash Hash the record was attempted for.
     */
    error UnexpectedSessionFulfillment(bytes32 intentHash);

    /**
     * @notice After the session's fulfill, no aligned fulfillment record landed (belt-and-braces re-check
     *         of the {UnexpectedSessionFulfillment} gate).
     * @param intentHash Hash of the misaligned intent.
     */
    error MisalignedFulfillment(bytes32 intentHash);

    /**
     * @notice The rate-derived slice for a leg is below the intent's `minTokens` floor (the pool is too
     *         small — the floor is the dust guard).
     * @param leg The offending leg index.
     * @param slice The rate-derived slice amount.
     * @param floor The committed `minTokens` floor.
     */
    error SliceBelowFloor(uint256 leg, uint256 slice, uint256 floor);

    /**
     * @notice A pool reward leg carries a non-zero `flat` — pools must be pure rate legs (the fee is the
     *         rate spread; a per-slice flat cannot be expressed under the full-pool advance).
     * @param leg The offending leg index.
     */
    error FlatLegUnsupported(uint256 leg);

    /**
     * @notice A paired pool reward leg has `rate == 0` — the pool cannot be converted into a slice.
     * @param leg The offending leg index.
     */
    error ZeroRateLeg(uint256 leg);

    /**
     * @notice The reward legs do not pair 1:1 with the input legs — a pool intent must not carry extra
     *         (flat-only) reward legs (an unpaired pool leg would leak to the claimant as pure margin).
     * @param rewardLegs The reward leg count.
     * @param inputLegs The `route.minTokens` leg count.
     */
    error UnpairedLegs(uint256 rewardLegs, uint256 inputLegs);

    /**
     * @notice The stream was closed by the keeper ({IStreamingPolicy-markClosed}); no further slices.
     * @param intentHash Hash of the closed pool intent.
     */
    error StreamClosed(bytes32 intentHash);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a pool slice is flash-fulfilled.
     * @param intentHash Hash of the pool intent
     * @param claimant Claimant that received the margin (cross-VM identifier)
     * @param fulfilled Per-leg slice input amounts, index-aligned with `route.minTokens`
     * @param margins Per-leg margins forwarded to the claimant, index-aligned with `reward.tokens`
     */
    event FlashSliceFulfilled(
        bytes32 indexed intentHash,
        bytes32 indexed claimant,
        uint256[] fulfilled,
        uint256[] margins
    );

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Atomically advances the ENTIRE pool to this policy, stages the rate-derived slice back as
     *         the route input, executes the route, records the slice (consumed at birth), and forwards
     *         the pool remainder to `claimant` — the solver fronts ZERO capital.
     * @dev FULL-POOL ADVANCE: for each paired leg `j`, `slice[j] = pool[j] * WAD / rate[j]` (rounded
     *      down; must be >= the `minTokens[j]` floor). The escrow account is EMPTY during the fulfill, so
     *      a balance-reading runtime legitimately consumes exactly the staged slice (route payloads commit
     *      CONFIG only — no amounts). With non-empty `solverData` the advance is handed to the caller via
     *      {IFlashSolver-onFlashAdvance} (swap mode); with empty `solverData` the slice is funded from the
     *      advance directly (same-token / deposit mode). The intent stays `Funded`; top-ups are direct
     *      transfers to the escrow account. Permissionless and front-runnable.
     * @param protocolVersion Creator-declared Portal implementation version committed in the intent hash
     * @param route Route information for the pool intent
     * @param reward Reward details for the pool intent (`reward.prover` must be this policy)
     * @param claimant Cross-VM identifier that receives the margin and is committed in the slice
     * @param solverData Empty for direct funding; otherwise opaque data forwarded to the caller's
     *        {IFlashSolver-onFlashAdvance} callback
     * @return results The runtime's raw return data from the fulfill execution
     */
    function flashSlice(
        uint32 protocolVersion,
        Route calldata route,
        Reward calldata reward,
        bytes32 claimant,
        bytes calldata solverData
    ) external payable returns (bytes memory results);
}
