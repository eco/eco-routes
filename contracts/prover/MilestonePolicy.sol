// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StreamingSchedulePolicy} from "./StreamingSchedulePolicy.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {Reward} from "../types/Intent.sol";

/**
 * @title MilestonePolicy
 * @notice The MILESTONE-GATED settlement policy: after a SINGLE fulfillment the reward is released in
 *         tranches, one tranche each time a bound off-chain attestor signals the next milestone. THE MODE
 *         IS THE POLICY — a milestone intent simply names this contract at `reward.prover`. Standalone
 *         (adds NO Portal bytecode); settles through the Portal's re-settleable path
 *         ({StreamingSchedulePolicy}).
 * @dev SCHEDULE PARAMS (`reward.hooks`): `abi.encode(address attestor, uint16[] trancheBps)` with
 *      `Σ trancheBps == 10000` (committed in the reward hash — the schedule a solver inspects is the one
 *      that settles, and the named attestor is the only address that can advance milestones). `attestor`
 *      is bound to the intent from the committed `hooks` on the FIRST settle (a `reached == 0` settle that
 *      pays nothing), after which {markMilestone} trusts only the bound value.
 *
 *      RELEASE: `reachedBps = Σ trancheBps[0 .. reached-1]`; per leg `entitled = fulfilled*rate/WAD + flat`
 *      (fixed full reward, `flat` folded in once); `unlocked = entitled * reachedBps / 10000`; the settle
 *      releases `unlocked - releasedSoFar`. Each milestone lets the claimant draw the newly-unlocked
 *      tranche on a fresh settle; the monotonic `releasedSoFar` ledger (NOT proof consumption) prevents a
 *      re-drain.
 *
 *      L1: {StreamingSchedulePolicy-consumeStreamClaims} caps each tranche at the live Account balance and
 *      advances `releasedSoFar` by the PAID amount, so an under-funded tranche's shortfall is recoverable
 *      after a top-up (the cumulative-unlocked-minus-PAID form captures it on the next draw).
 */
contract MilestonePolicy is StreamingSchedulePolicy {
    /// @notice Basis-points denominator: the tranche shares must sum to this.
    uint16 internal constant TOTAL_BPS = 10000;

    /// @notice Identifies this policy's settlement mechanism.
    string public constant PROOF_TYPE = "Milestone";

    /// @notice Cumulative count of milestones reached for an intent (monotonic).
    /// @dev `reached == k` means milestones `0 … k-1` are met (cumulative share `Σ trancheBps[0 .. k-1]`).
    mapping(bytes32 => uint256) public reached;

    /// @notice The attestor bound to an intent (zero until the first settle binds it from `reward.hooks`).
    mapping(bytes32 => address) public attestorOf;

    /// @notice `reward.hooks` is missing/malformed, or the tranches do not sum to 10000.
    error InvalidMilestoneSchedule();

    /// @notice {markMilestone} called before the attestor was bound (no settle has run yet).
    error AttestorNotBound(bytes32 intentHash);

    /// @notice {markMilestone} caller is not the bound attestor.
    error NotAttestor(bytes32 intentHash, address caller);

    /// @notice The signalled milestone index is not the next sequential one.
    error NonSequentialMilestone(
        bytes32 intentHash,
        uint256 expected,
        uint256 provided
    );

    /// @notice Emitted when a milestone is signalled (advances `reached`).
    event MilestoneReached(
        bytes32 indexed intentHash,
        uint256 indexed milestoneIndex,
        uint256 reached
    );

    /// @notice Emitted when the attestor is bound to an intent (first settle).
    event AttestorBound(bytes32 indexed intentHash, address indexed attestor);

    /**
     * @notice Initializes the MilestonePolicy.
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
     * @notice Signal that the next milestone for an intent has been met (advances `reached`).
     * @dev Only the attestor bound on the first settle may call, and milestones must be signalled
     *      sequentially (`milestoneIndex` MUST equal the current `reached`). Each call unlocks the next
     *      tranche on the following settle; the authoritative `reached <= trancheBps.length` bound is
     *      enforced at settle where the committed schedule is supplied ({_reachedBps}).
     * @param intentHash The intent whose milestone is reached.
     * @param milestoneIndex The milestone being signalled; must equal the current `reached`.
     */
    function markMilestone(
        bytes32 intentHash,
        uint256 milestoneIndex
    ) external {
        address attestor = attestorOf[intentHash];
        if (attestor == address(0)) revert AttestorNotBound(intentHash);
        if (msg.sender != attestor) revert NotAttestor(intentHash, msg.sender);

        uint256 current = reached[intentHash];
        if (milestoneIndex != current) {
            revert NonSequentialMilestone(intentHash, current, milestoneIndex);
        }

        uint256 next = current + 1;
        reached[intentHash] = next;
        emit MilestoneReached(intentHash, milestoneIndex, next);
    }

    /**
     * @notice The releasable amount for an intent's CURRENT reached/released state (off-chain view).
     * @dev Equals what a settle would release right now, WITHOUT the balance cap.
     * @param intentHash The intent to preview.
     * @param reward The reward spec.
     * @param fulfilled The single fulfillment's per-leg delivered amounts.
     * @return payNow Per-leg newly-unlocked increment (index-aligned with `reward.tokens`).
     */
    function releasable(
        bytes32 intentHash,
        Reward calldata reward,
        uint256[] calldata fulfilled
    ) external view returns (uint256[] memory payNow) {
        (, uint256 reachedBps) = _reachedBps(intentHash, reward);
        payNow = _unlocked(intentHash, reward, fulfilled, reachedBps);
    }

    /**
     * @inheritdoc StreamingSchedulePolicy
     * @dev Binds the attestor from the committed `reward.hooks` on the first settle, then returns the
     *      cumulative-unlocked-minus-released increment per leg.
     */
    function _scheduleIncrement(
        bytes32 intentHash,
        Reward calldata reward,
        uint256[] memory fulfilled
    ) internal override returns (uint256[] memory payNow) {
        (address attestor, uint256 reachedBps) = _reachedBps(
            intentHash,
            reward
        );
        if (attestorOf[intentHash] == address(0)) {
            attestorOf[intentHash] = attestor;
            emit AttestorBound(intentHash, attestor);
        }
        payNow = _unlocked(intentHash, reward, fulfilled, reachedBps);
    }

    /**
     * @notice The per-leg newly-unlocked increment `entitled*reachedBps/10000 - releasedSoFar`.
     * @param intentHash Keys the released-so-far ledger.
     * @param reward The reward spec (rate/flat legs).
     * @param fulfilled The single fulfillment's per-leg delivered amounts.
     * @param reachedBps The cumulative basis points unlocked so far.
     * @return payNow Per-leg newly-unlocked increment (index-aligned with `reward.tokens`).
     */
    function _unlocked(
        bytes32 intentHash,
        Reward calldata reward,
        uint256[] memory fulfilled,
        uint256 reachedBps
    ) internal view returns (uint256[] memory payNow) {
        uint256[] memory entitled = _entitled(reward, fulfilled);
        uint256 legCount = entitled.length;
        payNow = new uint256[](legCount);
        for (uint256 j; j < legCount; ++j) {
            uint256 unlocked = (entitled[j] * reachedBps) / TOTAL_BPS;
            uint256 already = releasedSoFar[intentHash][j];
            payNow[j] = unlocked > already ? unlocked - already : 0;
        }
    }

    /**
     * @notice Decodes + validates the committed schedule and returns the cumulative reached basis points.
     * @dev `reward.hooks = abi.encode(address attestor, uint16[] trancheBps)`, `Σ trancheBps == 10000`,
     *      non-zero attestor, at least one tranche. Enforces the authoritative milestone bound
     *      (`reached <= trancheBps.length` — the schedule length is only known here). Reverts
     *      {InvalidMilestoneSchedule} on any violation.
     * @param intentHash The intent (for the reached lookup).
     * @param reward The reward spec (its `hooks` carry the schedule).
     * @return attestor The committed attestor.
     * @return reachedBps The cumulative basis points unlocked by the reached milestones.
     */
    function _reachedBps(
        bytes32 intentHash,
        Reward calldata reward
    ) internal view returns (address attestor, uint256 reachedBps) {
        if (reward.hooks.length == 0) revert InvalidMilestoneSchedule();

        uint16[] memory trancheBps;
        (attestor, trancheBps) = abi.decode(reward.hooks, (address, uint16[]));

        uint256 trancheCount = trancheBps.length;
        if (attestor == address(0) || trancheCount == 0) {
            revert InvalidMilestoneSchedule();
        }

        uint256 reachedCount = reached[intentHash];
        if (reachedCount > trancheCount) revert InvalidMilestoneSchedule();

        uint256 total;
        for (uint256 i; i < trancheCount; ++i) {
            total += trancheBps[i];
            if (i < reachedCount) reachedBps += trancheBps[i];
        }
        if (total != TOTAL_BPS) revert InvalidMilestoneSchedule();
    }
}
