// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StreamingSchedulePolicy} from "./StreamingSchedulePolicy.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {Reward} from "../types/Intent.sol";

/**
 * @title VestingPolicy
 * @notice The LINEAR-VESTING settlement policy: a SINGLE fulfillment whose entitled reward is released
 *         LINEARLY over a window that starts at the FIRST settle, re-settled to draw each newly-vested
 *         increment. THE MODE IS THE POLICY — a vesting intent simply names this contract at
 *         `reward.prover`. It is a standalone contract (adds NO Portal bytecode) and settles through the
 *         Portal's re-settleable path ({StreamingSchedulePolicy}).
 * @dev SCHEDULE: `entitled[j] = fulfilled[j]*rate/WAD + flat` (the fixed full reward; `flat` folded in
 *      ONCE for the whole window, released pro-rata with the vest). The vest clock runs over
 *      `[t0, t0 + vestDuration]` where `t0` is the first settle. Each settle releases
 *      `vested(entitled) - releasedSoFar`, where `vested(e) = e` once fully vested else
 *      `Math.mulDiv(e, elapsed, vestDuration)` (rounds DOWN toward escrow; the fully-vested clamp means
 *      integer rounding never under-pays the final tranche). `vestDuration` is decoded from `reward.hooks`
 *      (`abi.encode(uint64 vestDuration)`), committed in the reward hash.
 *
 *      L1: {StreamingSchedulePolicy-consumeStreamClaims} caps each increment at the live Account balance and
 *      advances `releasedSoFar` by the PAID amount, so an under-funded vest's shortfall is recoverable
 *      after a top-up (never forfeited). `entitled = min(minTokens-based reward, escrow)` holds because the
 *      escrow cap IS the balance cap.
 */
contract VestingPolicy is StreamingSchedulePolicy {
    /// @notice Identifies this policy's settlement mechanism.
    string public constant PROOF_TYPE = "Vesting";

    /// @notice Vest start (unix seconds) — the time of the FIRST settle for an intent (0 until then).
    mapping(bytes32 => uint64) public vestStart;

    /// @notice `reward.hooks` is missing/malformed for a vesting intent.
    /// @dev Must be `abi.encode(uint64 vestDuration)` (>= 32 bytes) with a non-zero `vestDuration`.
    error InvalidVestSchedule();

    /**
     * @notice Initializes the VestingPolicy.
     * @param portal The local Portal/Inbox.
     * @param relays Relays authorized to push cross-chain facts via {recordBatch}.
     */
    constructor(
        address portal,
        bytes32[] memory relays
    ) StreamingSchedulePolicy(portal, relays) {}

    /// @inheritdoc IPolicy
    function getProofType() external pure returns (string memory) {
        return PROOF_TYPE;
    }

    /**
     * @notice The releasable increment at the current time, for an intent's CURRENT state (off-chain view).
     * @dev Equals what a settle would release right now given the recorded `vestStart` and
     *      `releasedSoFar`, WITHOUT the balance cap (a solver caps against the live Account balance
     *      off-chain). Before the first settle (`vestStart == 0`) it projects the clock starting now.
     * @param intentHash The intent to preview.
     * @param reward The reward spec.
     * @param fulfilled The single fulfillment's per-leg delivered amounts.
     * @return payNow Per-leg newly-vested increment (index-aligned with `reward.tokens`).
     */
    function releasable(
        bytes32 intentHash,
        Reward calldata reward,
        uint256[] calldata fulfilled
    ) external view returns (uint256[] memory payNow) {
        uint64 start = vestStart[intentHash];
        if (start == 0) start = uint64(block.timestamp);
        payNow = _vested(intentHash, reward, fulfilled, start);
    }

    /**
     * @inheritdoc StreamingSchedulePolicy
     * @dev Records the vest start on the first settle, then returns `vested(entitled) - releasedSoFar` per
     *      leg. The proof is never consumed — re-settleable until fully drawn.
     */
    function _scheduleIncrement(
        bytes32 intentHash,
        Reward calldata reward,
        uint256[] memory fulfilled
    ) internal override returns (uint256[] memory payNow) {
        uint64 start = vestStart[intentHash];
        if (start == 0) {
            start = uint64(block.timestamp);
            vestStart[intentHash] = start;
        }
        payNow = _vested(intentHash, reward, fulfilled, start);
    }

    /**
     * @notice The per-leg newly-vested increment `vested(entitled) - releasedSoFar`, clamped at 0.
     * @param intentHash Keys the released-so-far ledger.
     * @param reward The reward spec (rate/flat legs; `hooks` carries `vestDuration`).
     * @param fulfilled The single fulfillment's per-leg delivered amounts.
     * @param start The vest start `t0` (recorded, or projected-now for the pre-start view).
     * @return payNow Per-leg newly-vested increment (index-aligned with `reward.tokens`).
     */
    function _vested(
        bytes32 intentHash,
        Reward calldata reward,
        uint256[] memory fulfilled,
        uint64 start
    ) internal view returns (uint256[] memory payNow) {
        uint64 duration = _vestDuration(reward);
        uint256[] memory entitled = _entitled(reward, fulfilled);

        bool fullyVested = block.timestamp >=
            uint256(start) + uint256(duration);
        uint256 elapsed = block.timestamp > start ? block.timestamp - start : 0;

        uint256 legCount = entitled.length;
        payNow = new uint256[](legCount);
        for (uint256 j; j < legCount; ++j) {
            uint256 e = entitled[j];
            if (e == 0) continue;
            uint256 vested = fullyVested
                ? e
                : Math.mulDiv(e, elapsed, duration);
            uint256 already = releasedSoFar[intentHash][j];
            payNow[j] = vested > already ? vested - already : 0;
        }
    }

    /**
     * @notice Decodes and validates `uint64 vestDuration` from `reward.hooks`.
     * @dev `abi.encode(uint64 vestDuration)` (>= 32 bytes) with a non-zero duration; else reverts.
     */
    function _vestDuration(
        Reward calldata reward
    ) internal pure returns (uint64 duration) {
        if (reward.hooks.length < 32) revert InvalidVestSchedule();
        duration = abi.decode(reward.hooks, (uint64));
        if (duration == 0) revert InvalidVestSchedule();
    }
}
