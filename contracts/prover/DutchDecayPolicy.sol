// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ScheduledPolicy} from "./ScheduledPolicy.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {RewardMath} from "../libs/RewardMath.sol";
import {Reward, RewardToken, WAD} from "../types/Intent.sol";

/**
 * @title DutchDecayPolicy
 * @notice The DUTCH-AUCTION settlement policy: a SINGLE release whose effective reward rate moves over
 *         time between a start and end multiplier, so the settle timing fixes the payout. THE MODE IS THE
 *         POLICY — a Dutch intent simply names this contract at `reward.prover`. Standalone (adds NO
 *         Portal bytecode); settles through the one-shot atomic path ({IntentSource-settle}), which is the
 *         right fit for a SINGLE release: the atomic path caps each leg at the Account balance and sweeps
 *         the residual back to the keeper (so the keeper over-funds for the PEAK multiplier and gets the
 *         change back), and its terminal status is the idempotency (no re-settle, no policy ledger).
 * @dev The atomic settle reads {provenIntents} (the RAW recorded fact, so the preimage check passes) and
 *      the Account consults {previewRelease} for the per-leg amounts. {previewRelease} applies a time-varying
 *      WAD multiplier `mul` to each leg's `rate`: `payNow[j] = fulfilled[j]*(rate*mul/WAD)/WAD + flat`
 *      (the one-time `flat` is unscaled). `mul` is sampled from `block.timestamp` at the (one) settle.
 *
 *      DUTCH PARAMS are decoded from `reward.hooks` (committed in the reward hash):
 *        `abi.encode(uint256 startMulWad, uint256 endMulWad, uint64 auctionStart, uint64 window)`
 *      (>= 128 bytes). A Dutch intent carries its params in `hooks` INSTEAD of delegate hooks. NOTE: the
 *      atomic settle still attempts to run `reward.hooks` as a delegate hook AFTER paying (CEI); the
 *      attempt is caught by the Portal (try/catch) and surfaced as a benign {IIntentSource-HookReverted}
 *      event — it has no effect on the (already-paid) settle. This is the one cosmetic cost of carrying
 *      params in `hooks` on the atomic path.
 *
 *      DECAY: `mul` is `startMulWad` before `auctionStart`, `endMulWad` at/after `auctionStart + window`
 *      (or a zero window), and linearly interpolated in between (signed-safe for both decay and growth;
 *      rounds toward the start multiplier so it never leaves `[min(start,end), max(start,end)]`). The
 *      core caps each `payNow` at the Account balance, so a multiplier `> 1` can authorize more than the
 *      rate term but never more than the escrowed reward.
 */
contract DutchDecayPolicy is ScheduledPolicy {
    /// @notice Identifies this policy's settlement mechanism.
    string public constant PROOF_TYPE = "DutchDecay";

    /// @notice `reward.hooks` is missing/malformed for a Dutch-auction intent (< 128 bytes).
    error InvalidDutchSchedule();

    /**
     * @notice Initializes the DutchDecayPolicy.
     * @param portal The local Portal/Inbox.
     * @param relays Relays authorized to push cross-chain facts via {recordProof}.
     */
    constructor(
        address portal,
        bytes32[] memory relays
    ) ScheduledPolicy(portal, relays) {}

    /// @inheritdoc IPolicy
    function getProofType() external pure returns (string memory) {
        return PROOF_TYPE;
    }

    /**
     * @notice Records a cross-chain fulfillment fact from a whitelisted relay (first-writer-wins).
     * @dev The Dutch policy settles through the atomic path, so the raw fact is recorded directly.
     * @param intentHash The fulfilled intent.
     * @param destination The fulfilling chain id.
     * @param fulfillmentHash The fulfillment commitment bridged from the destination.
     */
    function recordProof(
        bytes32 intentHash,
        uint64 destination,
        bytes32 fulfillmentHash
    ) external {
        _recordCrossProof(intentHash, destination, fulfillmentHash);
    }

    /**
     * @inheritdoc IPolicy
     * @dev Returns the RAW recorded fact (cross-chain first, else same-chain synth) so the atomic settle's
     *      preimage check passes — a Dutch intent settles once through {IntentSource-settle}.
     */
    function provenIntents(
        bytes32 intentHash
    ) external view returns (ProofData memory) {
        (uint64 destination, bytes32 fulfillmentHash) = _recordedFact(
            intentHash
        );
        return
            ProofData({
                destination: destination,
                fulfillmentHash: fulfillmentHash
            });
    }

    /**
     * @inheritdoc IPolicy
     * @dev The Dutch reward curve sampled at `block.timestamp`. PAIRED legs (`j < fulfilled.length`):
     *      `fulfilled[j] * (rate*mul/WAD) / WAD + flat` (only the rate term decays; `flat` is added once,
     *      unscaled). EXTRA legs (`j >= fulfilled.length`): flat-only. Index-aligned with `reward.tokens`
     *      (native folded in as a leg with `token == address(0)`). The Account caps each entry at its own
     *      balance and sweeps the residual to the keeper.
     */
    function previewRelease(
        Reward calldata reward,
        uint256[] calldata fulfilled
    ) external view returns (uint256[] memory payNow) {
        uint256 mul = _dutchMultiplier(reward);

        uint256 legCount = reward.tokens.length;
        uint256 fulfilledLen = fulfilled.length;
        payNow = new uint256[](legCount);
        for (uint256 j; j < legCount; ++j) {
            RewardToken calldata leg = reward.tokens[j];
            if (j < fulfilledLen) {
                uint256 effectiveRate = Math.mulDiv(leg.rate, mul, WAD);
                payNow[j] = RewardMath.reward(
                    fulfilled[j],
                    effectiveRate,
                    leg.flat
                );
            } else {
                payNow[j] = leg.flat;
            }
        }
    }

    /**
     * @notice The time-sampled WAD multiplier on the leg rate at the current `block.timestamp`.
     * @dev `startMulWad` before (or at) `auctionStart`; `endMulWad` at/after `auctionStart + window` or a
     *      zero window; otherwise a signed-safe linear interpolation (handles both decay `end < start`, the
     *      common Dutch case, and growth `end > start`) rounding `step` DOWN toward the start multiplier.
     * @param reward The reward spec whose `hooks` carry the Dutch params.
     * @return mul The WAD multiplier applied to each leg's rate.
     */
    function _dutchMultiplier(
        Reward calldata reward
    ) internal view returns (uint256 mul) {
        (
            uint256 startMulWad,
            uint256 endMulWad,
            uint64 auctionStart,
            uint64 window
        ) = _decodeDutchParams(reward);

        if (block.timestamp <= auctionStart) {
            return startMulWad;
        }
        uint256 elapsed = block.timestamp - auctionStart;
        if (window == 0 || elapsed >= window) {
            return endMulWad;
        }
        if (endMulWad >= startMulWad) {
            uint256 step = Math.mulDiv(
                endMulWad - startMulWad,
                elapsed,
                window
            );
            return startMulWad + step;
        } else {
            uint256 step = Math.mulDiv(
                startMulWad - endMulWad,
                elapsed,
                window
            );
            return startMulWad - step;
        }
    }

    /**
     * @notice Decodes `(startMulWad, endMulWad, auctionStart, window)` from `reward.hooks`.
     * @dev `abi.encode(uint256, uint256, uint64, uint64)` — at least 128 bytes; else reverts.
     */
    function _decodeDutchParams(
        Reward calldata reward
    )
        internal
        pure
        returns (
            uint256 startMulWad,
            uint256 endMulWad,
            uint64 auctionStart,
            uint64 window
        )
    {
        if (reward.hooks.length < 128) revert InvalidDutchSchedule();
        (startMulWad, endMulWad, auctionStart, window) = abi.decode(
            reward.hooks,
            (uint256, uint256, uint64, uint64)
        );
    }
}
