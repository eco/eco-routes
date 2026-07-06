// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Semver} from "../libs/Semver.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {IStreamingPolicy} from "../interfaces/IStreamingPolicy.sol";
import {IStreamingFlashPolicy} from "../interfaces/IStreamingFlashPolicy.sol";
import {IFlashSolver} from "../interfaces/IFlashSolver.sol";
import {IPortal} from "../interfaces/IPortal.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";
import {RewardMath} from "../libs/RewardMath.sol";
import {Route, Reward, RewardToken, IntentLib, WAD} from "../types/Intent.sol";

/// @notice Minimal view onto the Portal's deterministic per-intent Account address (Model C).
interface IAccountAddress {
    function accountAddress(
        bytes32 intentHash,
        uint64 roleChainId
    ) external view returns (address);
}

/**
 * @title StreamingFlashPolicy
 * @notice STANDING-POOL zero-capital same-chain flash policy: a pool intent's reward legs ARE a
 *         replenishable pool, drawn down in successive flash SLICES ({flashSlice}) with the solver
 *         fronting nothing — the fee is the protocol-enforced rate spread, never a payload fee.
 * @dev STANDALONE lean contract (deliberately NOT a {StreamingPolicy} subclass — no batch/relay
 *      machinery). It implements the {IStreamingPolicy} surface the Portal's
 *      {IIntentSource-settleStream}/{IIntentSource-closeStream} paths need, but every settlement effect is
 *      SESSION-GATED to its own atomic {flashSlice}:
 *
 *      FULL-POOL ADVANCE (per slice, one `nonReentrant` tx):
 *        1. Read the pool `P[j]` = the escrow Account's balance of each reward leg; derive the slice
 *           `X[j] = P[j] * WAD / rate[j]` (rounded down — the margin never goes negative), floor-checked
 *           against `minTokens[j]` (the dust guard). Pools must be PURE rate legs, paired 1:1 with the
 *           input legs ({FlatLegUnsupported} / {UnpairedLegs}).
 *        2. SESSION OPEN, then `settleStream`: the session-scoped {consumeStreamClaims} (consume-once)
 *           returns `[this -> P]`, so {IAccount-withdrawStream} pays the WHOLE pool to this policy
 *           (full-or-revert exact), the status stays `Funded`, and the escrow Account is EMPTY.
 *        3. Stage `X` back as the route input (directly from the advance, or via the caller's
 *           {IFlashSolver} swap callback) and run the real `fulfill`. Safety here is BY CONSTRUCTION, not
 *           via the conservation check: the advance already emptied the Account, so the only balance a
 *           BALANCE-READING runtime (payloads commit CONFIG only — no amounts) can see or burn is exactly
 *           the staged `X`, and the margin `pool - X` never enters the Account (it stays on this policy
 *           until forwarded after `fulfill`). `X` is the keeper's own pool money, so a misbehaving
 *           committed runtime is keeper self-harm bounded to one slice. (The reward-conservation
 *           postcondition is vacuous in this path — `escrowBefore == 0`, so `live >= 0` always holds; the
 *           bound is the empty-Account-then-stage-`X` construction, not that check.)
 *           {recordFulfillment} accepts only the session's expected real-claimant fact and the slice is
 *           CONSUMED AT BIRTH — it never enters an unsettled store, so it can never be settled again and
 *           never blocks {IIntentSource-closeStream}.
 *        4. MARGIN `P - X` (per leg, plus any native remainder) goes to the claimant. SESSION CLOSE.
 *
 *      OUTSIDE a session everything is inert: {recordFulfillment} REVERTS (a plain fulfill against a pool
 *      intent unwinds whole — flashSlice is the ONLY fulfillment path, which blocks plain-fulfill
 *      poisoning), {consumeStreamClaims} reverts, {provenIntents} is the zero fact (the generic one-shot
 *      `settle` can never match a preimage), and {hasUnsettledFulfillment} is false — so the keeper's
 *      {IIntentSource-closeStream} (refunding the pool, since the reward legs ARE the pool tokens) is
 *      always available between slices as the pool's native exit. Top-ups are direct transfers to the
 *      escrow Account; standing pools should commit effectively-infinite deadlines
 *      (`type(uint64).max`) so the permissionless post-deadline `refund` can never terminate the pool.
 */
contract StreamingFlashPolicy is
    IStreamingFlashPolicy,
    Semver,
    ReentrancyGuard
{
    using AddressConverter for bytes32;
    using SafeERC20 for IERC20;

    /**
     * @notice Address of the Portal (the permanent {PortalProxy}) this policy settles through.
     */
    IPortal private immutable _PORTAL;

    uint64 private immutable _CHAIN_ID;

    /**
     * @notice Sentinel for "no flash session in progress" (non-zero for cheaper session flips; not a
     *         reachable intent hash).
     */
    bytes32 private constant _NO_SESSION = bytes32(uint256(1));

    /// @notice Streams closed by the keeper via {IIntentSource-closeStream} -> {markClosed} (terminal).
    mapping(bytes32 => bool) public closed;

    /// @notice Audit counter: flash slices fulfilled per pool intent (facts are consumed at birth — this
    ///         and the events are the only record).
    mapping(bytes32 => uint256) public sliceCount;

    /// @notice The pool intent currently being flash-sliced ({_NO_SESSION} when idle).
    bytes32 private _sessionIntentHash;

    /// @notice The expected REAL fact (real claimant over the slice amounts) — the only record
    ///         {recordFulfillment} accepts during the session.
    bytes32 private _sessionExpectedFact;

    /// @notice The pinned session payout table `abi.encode([this], [pool])` served (once) to
    ///         {consumeStreamClaims}.
    bytes private _sessionPayoutData;

    /// @notice Whether the session advance was already consumed (consume-once double-release guard).
    bool private _sessionAdvanceConsumed;

    /// @notice Whether the session's aligned fulfillment record has landed.
    bool private _sessionRecorded;

    constructor(address portal) {
        if (portal == address(0)) {
            revert ZeroPortal();
        }
        _PORTAL = IPortal(portal);

        if (block.chainid > type(uint64).max) {
            revert ChainIdTooLarge(block.chainid);
        }
        _CHAIN_ID = uint64(block.chainid);

        _sessionIntentHash = _NO_SESSION;
    }

    function getProofType() external pure returns (string memory) {
        return "Streaming flash";
    }

    /// @inheritdoc IStreamingFlashPolicy
    function flashSlice(
        uint32 protocolVersion,
        Route calldata route,
        Reward calldata reward,
        bytes32 claimant,
        bytes calldata solverData
    ) external payable nonReentrant returns (bytes memory results) {
        if (
            claimant == bytes32(0) ||
            claimant == bytes32(uint256(uint160(address(this)))) ||
            !claimant.isValidAddress()
        ) {
            revert InvalidClaimant();
        }
        if (reward.prover != address(this)) {
            revert InvalidProver();
        }

        bytes32 routeHash = keccak256(abi.encode(route));
        // Same-chain by construction: the hash commits _CHAIN_ID on BOTH sides.
        bytes32 intentHash = IntentLib.hashIntent(
            protocolVersion,
            _CHAIN_ID,
            _CHAIN_ID,
            routeHash,
            keccak256(abi.encode(reward))
        );

        if (closed[intentHash]) {
            revert StreamClosed(intentHash);
        }

        // ---- Read the pool and derive the slice ------------------------------------------------------
        (uint256[] memory pool, uint256[] memory slice) = _poolAndSlice(
            route,
            reward,
            intentHash
        );

        // ---- SESSION OPEN ----------------------------------------------------------------------------
        _sessionIntentHash = intentHash;
        _sessionExpectedFact = IntentLib.fulfillmentHash(
            intentHash,
            claimant,
            slice
        );
        {
            address[] memory claimants = new address[](1);
            claimants[0] = address(this);
            uint256[][] memory payouts = new uint256[][](1);
            payouts[0] = pool;
            _sessionPayoutData = abi.encode(claimants, payouts);
        }
        _sessionAdvanceConsumed = false;
        _sessionRecorded = false;

        // ---- FULL-POOL ADVANCE: settleStream pays the whole pool to this policy ---------------------
        // The session-scoped {consumeStreamClaims} serves the pinned payout table exactly once;
        // {IAccount-withdrawStream} pays it full-or-revert. Status stays Funded; the escrow is now EMPTY.
        _PORTAL.settleStream(
            protocolVersion,
            _CHAIN_ID,
            _CHAIN_ID,
            routeHash,
            reward,
            ""
        );

        // ---- FUND + FULFILL (real claimant; conservation snapshot is 0) -----------------------------
        uint256 nativeNeeded = _stageInputs(
            route,
            reward,
            intentHash,
            pool,
            slice,
            solverData
        );
        results = _PORTAL.fulfill{value: nativeNeeded}(
            protocolVersion,
            _CHAIN_ID,
            _CHAIN_ID,
            route,
            reward,
            claimant,
            slice,
            address(this)
        );

        // ALIGNMENT: the session's expected real-claimant fact must have been recorded
        // ({recordFulfillment} already enforced it; belt-and-braces).
        if (!_sessionRecorded) {
            revert MisalignedFulfillment(intentHash);
        }

        // ---- MARGIN: pool minus slice (plus native remainder) to the claimant ------------------------
        uint256[] memory margins = _forwardMargin(reward, claimant.toAddress());

        // ---- SESSION CLOSE ---------------------------------------------------------------------------
        _sessionIntentHash = _NO_SESSION;
        _sessionExpectedFact = bytes32(0);
        delete _sessionPayoutData;
        _sessionAdvanceConsumed = false;
        _sessionRecorded = false;

        sliceCount[intentHash] += 1;
        emit FlashSliceFulfilled(intentHash, claimant, slice, margins);
    }

    // ---------------------------------------------------------------------
    // Session-gated IStreamingPolicy surface (Portal-driven)
    // ---------------------------------------------------------------------

    /**
     * @inheritdoc IPolicy
     * @dev SESSION-GATED and STRICT: outside an open flash session for exactly this intent it REVERTS
     *      ({NotFlashSession}) — {flashSlice} is the ONLY fulfillment path for a pool intent, so a plain
     *      `fulfill` naming this policy unwinds whole at this step (the solver loses nothing; this blocks
     *      plain-fulfill poisoning of the pool). During the session only the expected real-claimant fact
     *      is accepted, exactly once. The slice is CONSUMED AT BIRTH: it is never stored as unsettled
     *      (the advance already paid it), only counted + emitted for audit.
     */
    function recordFulfillment(
        bytes32 intentHash,
        uint64 /* destination */,
        bytes32 fulfillmentHash
    ) external {
        if (msg.sender != address(_PORTAL)) {
            revert NotPortal(msg.sender);
        }
        if (
            _sessionIntentHash == _NO_SESSION ||
            intentHash != _sessionIntentHash
        ) {
            revert NotFlashSession(intentHash);
        }
        if (_sessionRecorded) {
            revert IntentAlreadyFulfilled(intentHash);
        }
        if (fulfillmentHash != _sessionExpectedFact) {
            revert UnexpectedSessionFulfillment(intentHash);
        }
        _sessionRecorded = true;
        // Audit trail (consumed at birth — never enters an unsettled store).
        emit StreamSliceFulfilled(
            intentHash,
            sliceCount[intentHash],
            fulfillmentHash
        );
    }

    /**
     * @inheritdoc IStreamingPolicy
     * @dev SESSION-GATED, Portal-only, CONSUME-ONCE: serves the pinned session payout table (`[this ->
     *      pool]`) exactly once per session. Outside a session (or for any other intent) it reverts
     *      ({NotFlashSession}), so a generic `settleStream` against a pool intent can never move money; a
     *      second consume inside one session (e.g. a malicious runtime re-entering `settleStream`
     *      mid-fulfill) reverts {AdvanceAlreadyConsumed} — the advance can never be released twice. The
     *      supplied `batchData` is ignored (the session pins the payout).
     */
    function consumeStreamClaims(
        bytes32 intentHash,
        Reward calldata /* reward */,
        bytes calldata /* batchData */
    ) external returns (bytes memory payoutData) {
        if (msg.sender != address(_PORTAL)) {
            revert NotAuthorized(msg.sender);
        }
        if (
            _sessionIntentHash == _NO_SESSION ||
            intentHash != _sessionIntentHash
        ) {
            revert NotFlashSession(intentHash);
        }
        if (_sessionAdvanceConsumed) {
            revert AdvanceAlreadyConsumed(intentHash);
        }
        _sessionAdvanceConsumed = true;
        return _sessionPayoutData;
    }

    /**
     * @inheritdoc IStreamingPolicy
     * @dev Always false: slices are consumed at birth (paid by the advance inside their own atomic
     *      {flashSlice}), so no solver is ever owed a proven-but-unsettled fulfillment. The keeper's
     *      {IIntentSource-closeStream} is therefore always available between slices — the pool's native
     *      exit ({IAccount-refund} returns the pool, since the reward legs ARE the pool tokens).
     */
    function hasUnsettledFulfillment(
        bytes32 /* intentHash */
    ) external pure returns (bool) {
        return false;
    }

    /// @inheritdoc IStreamingPolicy
    function markClosed(bytes32 intentHash) external {
        if (msg.sender != address(_PORTAL)) {
            revert NotAuthorized(msg.sender);
        }
        closed[intentHash] = true;
        emit StreamMarkedClosed(intentHash);
    }

    /**
     * @inheritdoc IStreamingPolicy
     * @dev No cross-chain relays exist for a flash pool (slices settle atomically in-session); always
     *      reverts.
     */
    function recordBatch(
        bytes32 /* intentHash */,
        uint64 /* destination */,
        bytes32 /* batchHash */
    ) external view {
        revert NotAuthorized(msg.sender);
    }

    /**
     * @inheritdoc IPolicy
     * @dev Always the ZERO fact — even mid-session. Nothing consults it in-session (`settleStream`
     *      delegates wholly to {consumeStreamClaims}), and returning zero everywhere guarantees the
     *      generic one-shot {IIntentSource-settle} can never match a preimage against this policy, and
     *      the pre-deadline `refund` gate never sees a "valid proof" it would have to honor. Standing
     *      pools commit `reward.deadline = type(uint64).max`, making {IIntentSource-closeStream} the sole
     *      exit.
     */
    function provenIntents(
        bytes32 /* intentHash */
    ) external pure returns (ProofData memory) {
        return ProofData(0, bytes32(0));
    }

    /**
     * @inheritdoc IPolicy
     * @dev No-op: a flash pool has no unproven destination slices to dispatch (slices are consumed at
     *      birth). Must not revert.
     */
    function prove(
        address /* sender */,
        uint64 /* sourceChainDomainID */,
        bytes32[] calldata /* intentHashes */,
        bytes calldata /* data */
    ) external payable {
        // solhint-disable-previous-line no-empty-blocks
        // Intentionally empty: nothing to dispatch for an atomic flash pool.
    }

    /**
     * @inheritdoc IPolicy
     * @dev No-op: same-chain pool facts never leave this chain, so there is nothing to challenge.
     */
    function challengeIntentProof(
        uint32 /* protocolVersion */,
        uint64 /* source */,
        uint64 /* destination */,
        bytes32 /* routeHash */,
        bytes32 /* rewardHash */
    ) external pure {
        // solhint-disable-previous-line no-empty-blocks
        // Intentionally empty: same-chain pool intents cannot be challenged.
    }

    /**
     * @inheritdoc IPolicy
     * @dev The standard atomic curve, for interface completeness only — pool settlement never routes
     *      through the generic Account `withdraw`/`previewRelease` path ({provenIntents} is always zero,
     *      so `settle` can never reach it).
     */
    function previewRelease(
        Reward calldata reward,
        uint256[] calldata fulfilled
    ) external pure returns (uint256[] memory payNow) {
        uint256 legCount = reward.tokens.length;
        uint256 fulfilledLen = fulfilled.length;
        payNow = new uint256[](legCount);
        for (uint256 j; j < legCount; ++j) {
            RewardToken calldata leg = reward.tokens[j];
            if (j < fulfilledLen) {
                payNow[j] = RewardMath.reward(fulfilled[j], leg.rate, leg.flat);
            } else {
                payNow[j] = leg.flat;
            }
        }
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /**
     * @notice Reads the pool (the escrow Account's per-leg balances) and derives the rate-scaled slice.
     * @dev Pool legs must be PURE rate legs paired 1:1 with the input legs: `flat != 0` reverts
     *      {FlatLegUnsupported} (a per-slice flat cannot be expressed under the full-pool advance),
     *      `rate == 0` reverts {ZeroRateLeg}, and extra reward legs revert {UnpairedLegs} (an unpaired
     *      pool leg would leak to the claimant as pure margin). `slice[j] = pool[j] * WAD / rate[j]`
     *      rounds DOWN so the margin never goes negative; a `rate >= WAD` (the fee spread) guarantees the
     *      advance covers the slice in the same-token case. The `minTokens` floor is the dust guard
     *      ({SliceBelowFloor}).
     * @param route The route (its `minTokens` are the paired input legs)
     * @param reward The reward (its `tokens` are the pool legs)
     * @param intentHash The pool intent hash (locates the escrow Account)
     * @return pool Per-leg pool balances, index-aligned with `reward.tokens`
     * @return slice Per-leg slice input amounts, index-aligned with `route.minTokens`
     */
    function _poolAndSlice(
        Route calldata route,
        Reward calldata reward,
        bytes32 intentHash
    ) private view returns (uint256[] memory pool, uint256[] memory slice) {
        uint256 rewardLen = reward.tokens.length;
        uint256 inLen = route.minTokens.length;
        if (rewardLen != inLen) {
            revert UnpairedLegs(rewardLen, inLen);
        }

        // Same-chain: the source escrow and destination execution Accounts collapse to ONE address.
        address account = IAccountAddress(address(_PORTAL)).accountAddress(
            intentHash,
            _CHAIN_ID
        );

        pool = new uint256[](rewardLen);
        slice = new uint256[](inLen);
        for (uint256 j; j < rewardLen; ++j) {
            RewardToken calldata leg = reward.tokens[j];
            if (leg.flat != 0) {
                revert FlatLegUnsupported(j);
            }
            if (leg.rate == 0) {
                revert ZeroRateLeg(j);
            }
            pool[j] = leg.token == address(0)
                ? account.balance
                : IERC20(leg.token).balanceOf(account);
            slice[j] = Math.mulDiv(pool[j], WAD, leg.rate);
            if (slice[j] < route.minTokens[j].amount) {
                revert SliceBelowFloor(j, slice[j], route.minTokens[j].amount);
            }
        }
    }

    /**
     * @notice Funds the route inputs out of the pool advance (direct mode) or via the caller's swap
     *         callback — mirrors {SameChainFlashPolicy}'s staging.
     * @param route The route (its `minTokens` are the input legs)
     * @param reward The reward (its `tokens` shape the advance)
     * @param intentHash The session intent hash (passed to the callback)
     * @param advance Per-leg advance amounts (the full pool), index-aligned with `reward.tokens`
     * @param inputAmounts Per-leg slice amounts to stage, index-aligned with `route.minTokens`
     * @param solverData Empty for direct mode; otherwise forwarded to the caller's callback
     * @return nativeNeeded The native input-leg amount to forward into the fulfill
     */
    function _stageInputs(
        Route calldata route,
        Reward calldata reward,
        bytes32 intentHash,
        uint256[] memory advance,
        uint256[] memory inputAmounts,
        bytes calldata solverData
    ) private returns (uint256 nativeNeeded) {
        bool swapMode = solverData.length != 0;

        if (swapMode) {
            uint256 rewardLen = reward.tokens.length;
            for (uint256 i; i < rewardLen; ++i) {
                uint256 amount = advance[i];
                if (amount == 0) {
                    continue;
                }
                address token = reward.tokens[i].token;
                if (token == address(0)) {
                    (bool ok, ) = msg.sender.call{value: amount}("");
                    if (!ok) {
                        revert NativeTransferFailed();
                    }
                } else {
                    _transferToken(IERC20(token), msg.sender, amount);
                }
            }
            IFlashSolver(msg.sender).onFlashAdvance(
                intentHash,
                advance,
                solverData
            );
        }

        uint256 inLen = route.minTokens.length;
        for (uint256 j; j < inLen; ++j) {
            address token = route.minTokens[j].token;
            uint256 amount = inputAmounts[j];
            if (token == address(0)) {
                nativeNeeded = amount;
                continue;
            }
            if (amount == 0) {
                continue;
            }
            if (swapMode) {
                IERC20(token).safeTransferFrom(
                    msg.sender,
                    address(this),
                    amount
                );
            }
            IERC20(token).safeIncreaseAllowance(address(_PORTAL), amount);
        }
    }

    /**
     * @notice Forwards the margin — every remaining reward-leg ERC20 balance plus the full native balance
     *         — to the claimant, reporting the per-leg amounts.
     * @dev Native is best-effort (v2 parity): a rejecting claimant leaves it here as the next flash
     *      caller's bonus.
     * @param reward The reward whose token legs define the margin columns
     * @param claimantAddr The margin recipient
     * @return margins Per-leg margins forwarded, index-aligned with `reward.tokens`
     */
    function _forwardMargin(
        Reward calldata reward,
        address claimantAddr
    ) private returns (uint256[] memory margins) {
        uint256 rewardLen = reward.tokens.length;
        margins = new uint256[](rewardLen);
        uint256 nativeIdx = type(uint256).max;
        for (uint256 i; i < rewardLen; ++i) {
            address token = reward.tokens[i].token;
            if (token == address(0)) {
                nativeIdx = i;
                continue;
            }
            uint256 balance = IERC20(token).balanceOf(address(this));
            margins[i] = balance;
            if (balance > 0) {
                _transferToken(IERC20(token), claimantAddr, balance);
            }
        }

        uint256 nativeBalance = address(this).balance;
        if (nativeIdx != type(uint256).max) {
            margins[nativeIdx] = nativeBalance;
        }
        if (nativeBalance > 0) {
            // Best-effort (v2 parity) — failure leaves the native here for the next flash caller.
            // solhint-disable-next-line avoid-low-level-calls
            claimantAddr.call{value: nativeBalance}("");
        }
    }

    /**
     * @notice Transfers ERC20 tokens out of the policy.
     * @dev Virtual so subclasses can override for non-standard tokens (e.g. Tron USDT).
     * @param token ERC20 token to transfer
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _transferToken(
        IERC20 token,
        address to,
        uint256 amount
    ) internal virtual {
        token.safeTransfer(to, amount);
    }

    /**
     * @notice Allows the policy to receive native tokens (the pool advance, solver native repayment).
     */
    receive() external payable {}
}
