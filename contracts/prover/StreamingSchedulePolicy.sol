// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ScheduledPolicy} from "./ScheduledPolicy.sol";
import {IStreamingPolicy} from "../interfaces/IStreamingPolicy.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";
import {RewardMath} from "../libs/RewardMath.sol";
import {Reward, RewardToken, IntentLib} from "../types/Intent.sol";

/// @notice Minimal view onto the Portal's deterministic per-intent Account address (Model C).
interface IAccountAddress {
    function accountAddress(
        bytes32 intentHash,
        uint64 roleChainId
    ) external view returns (address);
}

/**
 * @title StreamingSchedulePolicy
 * @notice Shared base for the RE-SETTLEABLE schedule policies (Vesting, Milestone) — a SINGLE fulfillment
 *         whose reward is drawn in increments over a schedule. It reuses the Portal's re-settleable settle
 *         entry ({IIntentSource-settleStream} -> {IStreamingPolicy-consumeStreamClaims} ->
 *         {IAccount-withdrawStream}) so it adds ZERO Portal bytecode: `settleStream` keeps the intent
 *         `Funded` (re-settleable) and pays the policy-computed payouts WITHOUT sweeping the residual (it
 *         funds later increments) — exactly what a schedule needs. The one-shot atomic `settle` would
 *         instead terminate the intent and sweep the residual, so it is BLOCKED here (see
 *         {provenIntents}).
 * @dev These policies implement {IStreamingPolicy} purely to reach the generic re-settleable settle path;
 *      they are NOT streams (no slices, no batches — a single fulfillment). The single `(claimant,
 *      fulfilled)` preimage is supplied at each settle and verified against the recorded fact; the
 *      per-leg increment is the SCHEDULE (the virtual {_scheduleIncrement}) minus the monotonic
 *      released-so-far ledger.
 *
 *      L1 (under-funded recoverable): {consumeStreamClaims} caps each per-leg payout at the LIVE source
 *      Account balance BEFORE advancing `releasedSoFar`, so the ledger tracks cumulative PAID (not the
 *      uncapped entitled increment). An under-funded settle pays what the Account holds and advances the
 *      ledger by exactly that; the shortfall stays recoverable on a later (topped-up) settle and is never
 *      forfeited to the keeper. Because the payouts are pre-capped, {IAccount-withdrawStream} always pays
 *      them in full (never reverts) in the SAME transaction with no fund movement between the balance read
 *      and the pay.
 *
 *      SCHEDULE PARAMS are decoded from `reward.hooks` (committed in the reward hash, so the schedule a
 *      solver inspects is the schedule that settles). A schedule intent therefore carries its schedule in
 *      `hooks` INSTEAD of delegate hooks; that is fine because the re-settleable settle path
 *      (`settleStream`) never runs `reward.hooks` as a hook.
 */
abstract contract StreamingSchedulePolicy is ScheduledPolicy, IStreamingPolicy {
    using AddressConverter for bytes32;

    /// @notice Per-intent, per-reward-leg amount already PAID (monotonic; the L1 ledger).
    /// @dev Keyed by `(intentHash, legIndex)` where `legIndex` indexes `reward.tokens` (native folded in
    ///      as a leg with `token == address(0)`). The reward legs are committed in the intent hash, so the
    ///      index keying is stable across settles. Advanced by the BALANCE-CAPPED payout (cumulative PAID),
    ///      so an under-funded increment's shortfall is recoverable on a later settle (L1).
    mapping(bytes32 => mapping(uint256 => uint256)) public releasedSoFar;

    /// @notice Whether the keeper has CLOSED the schedule (terminal record; set via {markClosed}).
    mapping(bytes32 => bool) public closed;

    /// @notice Emitted on each schedule settle (an increment drawn against the single fulfillment).
    /// @param intentHash The settled intent.
    /// @param claimant The committed claimant paid the increment.
    event ScheduleSettled(bytes32 indexed intentHash, bytes32 indexed claimant);

    /**
     * @notice Wires the Portal and whitelisted cross-chain relays.
     * @param portal The local Portal/Inbox.
     * @param relays Relays authorized to push cross-chain facts via {recordBatch}.
     */
    constructor(
        address portal,
        bytes32[] memory relays
    ) ScheduledPolicy(portal, relays) {}

    // ---------------------------------------------------------------------
    // Cross-chain relay receipt (the IStreamingPolicy name; single fact, not a batch)
    // ---------------------------------------------------------------------

    /**
     * @inheritdoc IStreamingPolicy
     * @dev For a single-fulfillment schedule the `batchHash` argument IS the fulfillment commitment; a
     *      whitelisted relay records it as the cross-chain fact (first-writer-wins).
     */
    function recordBatch(
        bytes32 intentHash,
        uint64 destination,
        bytes32 batchHash
    ) external {
        _recordCrossProof(intentHash, destination, batchHash);
    }

    // ---------------------------------------------------------------------
    // Re-settleable settle (the generic settleStream path)
    // ---------------------------------------------------------------------

    /**
     * @inheritdoc IStreamingPolicy
     * @dev Verifies the single `(claimant, fulfilled)` preimage against the recorded fact, computes the
     *      per-leg schedule increment ({_scheduleIncrement}), caps it at the live Account balance and
     *      advances the PAID ledger (L1), then returns the single-slice payout table the Account pays. Only
     *      the Portal may call. `batchData` is `abi.encode(bytes32 claimant, uint256[] fulfilled)` — the
     *      single fulfillment preimage (NOT the streaming {StreamBatch}[] shape); the Portal treats it as
     *      opaque.
     */
    function consumeStreamClaims(
        bytes32 intentHash,
        Reward calldata reward,
        bytes calldata batchData
    ) external returns (bytes memory payoutData) {
        if (msg.sender != PORTAL) revert NotAuthorized(msg.sender);

        (bytes32 claimant, uint256[] memory fulfilled) = abi.decode(
            batchData,
            (bytes32, uint256[])
        );

        // Verify the supplied preimage against the RAW recorded fact (same-chain or cross-chain).
        (, bytes32 rawFact) = _recordedFact(intentHash);
        if (
            rawFact == bytes32(0) ||
            IntentLib.fulfillmentHash(intentHash, claimant, fulfilled) !=
            rawFact
        ) {
            revert UnknownSlice(intentHash);
        }

        // The per-leg newly-releasable increment (the SCHEDULE minus released-so-far). May mutate
        // per-intent schedule state (e.g. record the vest start / bind the attestor on the first settle).
        // Then L1-cap it at the live Account balance and advance the PAID ledger by the capped amount.
        uint256[] memory payNow = _capAndAdvance(
            intentHash,
            reward,
            _scheduleIncrement(intentHash, reward, fulfilled)
        );

        address[] memory claimants = new address[](1);
        claimants[0] = claimant.toAddress();
        uint256[][] memory payouts = new uint256[][](1);
        payouts[0] = payNow;
        payoutData = abi.encode(claimants, payouts);

        emit ScheduleSettled(intentHash, claimant);
    }

    /**
     * @inheritdoc IStreamingPolicy
     * @dev A solver is owed the schedule as soon as the single fulfillment is recorded, so the keeper's
     *      terminal {IIntentSource-closeStream} is blocked from then on (it can only reclaim an
     *      UNfulfilled standing intent early). Once fulfilled, the keeper reclaims any residual via the
     *      deadline-gated {IIntentSource-refund}, the definitive settlement window.
     */
    function hasUnsettledFulfillment(
        bytes32 intentHash
    ) external view returns (bool) {
        (, bytes32 fh) = _recordedFact(intentHash);
        return fh != bytes32(0);
    }

    /// @inheritdoc IStreamingPolicy
    function markClosed(bytes32 intentHash) external {
        if (msg.sender != PORTAL) revert NotAuthorized(msg.sender);
        closed[intentHash] = true;
        emit StreamMarkedClosed(intentHash);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /**
     * @notice IPolicy: the settle-side fact view (tagged to block the one-shot atomic settle).
     * @dev Returns a NON-ZERO fact (with the real destination) whenever a fulfillment is recorded, so the
     *      source-side refund gate ({IntentSource-_validateRefund}) and owner-cook lock
     *      ({IntentSource-executeAsOwner}) see the intent as proven and protect the solver. The
     *      `fulfillmentHash` is a TAGGED value, NOT the raw single-fulfillment hash, so the generic
     *      one-shot {IntentSource-settle} preimage check FAILS on a schedule intent — a schedule MUST
     *      settle via {IntentSource-settleStream}. The atomic path would terminate the intent and sweep
     *      the residual to the keeper, which would break the schedule; failing its preimage check blocks
     *      it. {consumeStreamClaims} verifies against the raw fact, not this tag.
     */
    function provenIntents(
        bytes32 intentHash
    ) external view returns (ProofData memory) {
        (uint64 destination, bytes32 rawFact) = _recordedFact(intentHash);
        if (rawFact == bytes32(0)) {
            return ProofData({destination: 0, fulfillmentHash: bytes32(0)});
        }
        return
            ProofData({
                destination: destination,
                fulfillmentHash: _tag(rawFact)
            });
    }

    /**
     * @notice IPolicy: informational reward-total view (not consulted on the settle path).
     * @dev INFORMATIONAL only. A schedule never routes through the generic Account `withdraw`/`previewRelease`
     *      path (that path is blocked by {provenIntents}); settlement is via {consumeStreamClaims}. This
     *      returns the FULL entitled per-leg reward (rate+flat) so an off-chain caller can see the total,
     *      and cannot mislead settlement because it is never consulted on the settle path.
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
            payNow[j] = j < fulfilledLen
                ? RewardMath.reward(fulfilled[j], leg.rate, leg.flat)
                : leg.flat;
        }
    }

    /// @notice ERC165: also advertises {IStreamingPolicy} (the re-settleable settle surface).
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override returns (bool) {
        return
            interfaceId == type(IStreamingPolicy).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /**
     * @notice L1 balance cap + ledger advance: clamp each leg at the LIVE source Account balance and advance
     *         the PAID `releasedSoFar` ledger by the capped amount.
     * @dev The Account pays this exact (capped) table in the SAME transaction with no fund movement between
     *      the balance read and the pay, so {IAccount-withdrawStream} never reverts; advancing the ledger by
     *      PAID (not by the uncapped increment) keeps an under-funded increment's shortfall recoverable on
     *      a later (topped-up) settle. `source == CHAIN_ID` (settleStream is source-gated).
     * @param intentHash The intent being settled (keys the ledger + the Account address).
     * @param reward The reward spec (its `tokens` define the leg columns).
     * @param payNow The uncapped per-leg increment; mutated in place to the capped amounts.
     * @return The balance-capped per-leg payout.
     */
    function _capAndAdvance(
        bytes32 intentHash,
        Reward calldata reward,
        uint256[] memory payNow
    ) internal returns (uint256[] memory) {
        address account = IAccountAddress(PORTAL).accountAddress(
            intentHash,
            CHAIN_ID
        );
        uint256 legCount = reward.tokens.length;
        for (uint256 j; j < legCount; ++j) {
            if (payNow[j] != 0) {
                address token = reward.tokens[j].token;
                uint256 bal = token == address(0)
                    ? account.balance
                    : IERC20(token).balanceOf(account);
                if (payNow[j] > bal) {
                    payNow[j] = bal;
                }
                if (payNow[j] != 0) {
                    releasedSoFar[intentHash][j] += payNow[j];
                }
            }
        }
        return payNow;
    }

    /**
     * @notice The per-leg newly-releasable increment for this settle (the SCHEDULE minus released-so-far).
     * @dev Implemented by each concrete schedule (Vesting = linear-over-window; Milestone = reached
     *      tranches). MAY mutate per-intent schedule state (record the vest start, bind the attestor). The
     *      returned amounts are UNCAPPED; {consumeStreamClaims} balance-caps them and advances the PAID
     *      `releasedSoFar` ledger. Index-aligned with `reward.tokens`.
     * @param intentHash The intent being settled.
     * @param reward The reward spec (rate/flat legs; `hooks` carries the schedule params).
     * @param fulfilled The single fulfillment's core-verified per-leg delivered amounts (paired prefix).
     * @return payNow Per-leg uncapped newly-releasable amount.
     */
    function _scheduleIncrement(
        bytes32 intentHash,
        Reward calldata reward,
        uint256[] memory fulfilled
    ) internal virtual returns (uint256[] memory payNow);

    /**
     * @notice The full entitled per-leg reward (rate+flat), the FIXED total the schedule releases toward.
     * @dev `flat` is part of the fixed entitled total, so it is released pro-rata with the schedule and
     *      fully paid exactly when the schedule completes — charged once, no per-settle flat dust and no
     *      double-count (the monotonic `releasedSoFar` ledger keeps each portion paid once). Index-aligned
     *      with `reward.tokens` (native folded in as a leg). Shared by both concrete schedules.
     */
    function _entitled(
        Reward calldata reward,
        uint256[] memory fulfilled
    ) internal pure returns (uint256[] memory entitled) {
        uint256 legCount = reward.tokens.length;
        uint256 fulfilledLen = fulfilled.length;
        entitled = new uint256[](legCount);
        for (uint256 j; j < legCount; ++j) {
            RewardToken memory leg = reward.tokens[j];
            entitled[j] = j < fulfilledLen
                ? RewardMath.reward(fulfilled[j], leg.rate, leg.flat)
                : leg.flat;
        }
    }

    /**
     * @notice Tags a raw fulfillment hash so the exposed {provenIntents} value cannot pass the generic
     *         single-shot settle preimage check, while staying non-zero for the refund/lock gates.
     * @dev A distinct preimage structure from {IntentLib-fulfillmentHash}, so no collision is possible.
     */
    function _tag(bytes32 rawFact) internal pure returns (bytes32) {
        return keccak256(abi.encode("eco.routes.v3.schedule", rawFact));
    }
}
