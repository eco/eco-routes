/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IIntentSource} from "../interfaces/IIntentSource.sol";
import {Reward} from "../types/Intent.sol";
import {IntentTemplate} from "./IntentTemplate.sol";

/**
 * @title IntentChainer
 * @notice Funds and optionally publishes a second intent using a runtime-measured amount.
 * @dev Called as the last {Call} of an executing intent (intent1), at which point this contract holds the
 *      output of whatever intent1's earlier calls produced -- typically a DEX swap that named this contract
 *      as its recipient. It measures that balance -- the ONE runtime measurement in the whole flow -- and
 *      derives from it the two amounts of a second intent (intent2) whose every other field was fixed when
 *      intent1 was signed: `amountIn` is escrowed as intent2's reward, and
 *      `amountOut = ceil(amountIn * scale / WAD)` is available alongside amountIn to the route's typed
 *      items. A conventional amount-only route uses amountOut as its solver delivery obligation; scale
 *      carries the proportional margin and unit conversion. Nested vault items render downstream
 *      intents from that same measurement and splice their recipients into the route as data.
 *
 *      WHY THIS IS SAFE WITHOUT ACCESS CONTROL. Route calls reach every contract through the Portal's single
 *      shared {Executor}, which any fulfiller of any intent drives permissionlessly, so `msg.sender` proves
 *      only that "some route call is running" -- never whose. The authorization anchor is instead intent1's
 *      own hash: the entire {Order}, including intent2's route bytes and `reward.creator`, rides inside
 *      `intent1.route.calls[k].data`, which is covered by `keccak256(abi.encode(route))`, which is covered by
 *      the `intentHash` that {Inbox} re-derives and checks before executing anything. A solver cannot alter
 *      the order it is executing. The residual exposure is a balance donated to this contract out-of-band,
 *      which the next caller sweeps into their own intent; the intended flow never leaves a balance at rest.
 *
 *      WHY THIS CONTRACT IS NOT PAYABLE AND HAS NO `receive()`. Every {IIntentSource} funding entry point
 *      (`fund`, `fundFor`, `publishAndFund`, `publishAndFundFor`, `open`, `openFor`) ends in
 *      `Refund.excessNative()`, which forwards the Portal's ENTIRE native balance to `msg.sender`. Reached
 *      re-entrantly from inside a route call that is what this contract would be, so it would silently
 *      capture the solver's in-flight ETH. This contract therefore touches `publish` and nothing else.
 *
 *      PUBLISH IS OPTIONAL; SETTLEMENT CHECKS ARE NOT. The local Portal predicts the local reward vault.
 *      Its status is checked even when publish is false. Publishing emits the completed route and
 *      reward for discovery; it does not control where value moves. Funding is deliberately NOT called:
 *      withdraw accepts Status.Initial and pays from the live vault balance. Rendered remote vaults are
 *      only bytes inside the route and cannot redirect the local push.
 */
contract IntentChainer is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Types ============

    /**
     * @notice A locally funded child intent with a fully committed, dynamically rendered route.
     * @dev The entire template program, including downstream rewards, derivation tags/configs and node
     *      references, rides inside intent1's hashed calldata. Nested vaults are addresses inserted in
     *      the route, NOT recipients of this contract's local transfer. No new custody or approvals.
     *      Builders must choose fresh child route salts when independent children are intended. The
     *      parent hash is not mixed into the child hash; existing child-vault balances are permitted.
     * @param publish Whether to publish intent2 for discoverability. Settlement checks are unconditional.
     * @param portal The LOCAL Portal whose reward vault receives the measured token.
     * @param token The single local ERC20 measured and escrowed.
     * @param destination Intent2's route execution chain.
     * @param template Dependency-first downstream intents and the root route's segments/items.
     * @param reward Local reward: exactly one leg in token, no native amount. Its amount is overwritten.
     * @param scale WAD-denominated transform: amountOut = ceil(amountIn * scale / WAD). Carries both
     *        unit conversion and proportional spread (1e18 identity, 1e30 for 6->18, 1e6 for 18->6).
     *        Amount items explicitly select amountIn or amountOut and any further transform.
     * @param minAmountIn Reject a measured balance below this floor, reverting the outer fulfillment.
     */
    struct Order {
        bool publish;
        address portal;
        address token;
        uint64 destination;
        IntentTemplate.Program template;
        Reward reward;
        uint256 scale;
        uint256 minAmountIn;
    }

    // ============ Constants ============

    /// @notice Fixed-point denominator for {Order.scale}.
    /// @dev Decimal, not binary, so every power-of-ten unit conversion is exact in both directions. Matches
    ///      the WAD convention v3 adopts for `RewardToken.rate`.
    uint256 public constant WAD = 1e18;

    /// @notice Per-template item bound; nodes and aggregate rendered bytes are also bounded.
    uint256 public constant MAX_ITEMS = IntentTemplate.MAX_ITEMS;

    /// @notice Minimum time intent2's reward deadline must clear `block.timestamp` by.
    /// @dev Intent2's deadlines are fixed when intent1 is signed, but intent1 may be fulfilled at any point
    ///      up to its own route deadline. Publishing an intent2 that is already expired is recoverable (the
    ///      escrow refunds to `reward.creator` after the deadline) but burns intent1 for nothing, so it fails
    ///      loudly here instead.
    uint64 public constant MIN_DEADLINE_BUFFER = 5 minutes;

    // ============ Events ============

    /**
     * @notice A second intent was funded and optionally published from a measured balance.
     * @param intentHash Intent2's hash.
     * @param vault Intent2's deterministic vault, whose balance increased by at least `amountIn`.
     * @param token The measured token.
     * @param amountIn The measured amount, escrowed as intent2's reward.
     * @param amountOut The scaled amount available to template items selecting AmountSource.Output.
     * @param published Whether this call also emitted the Portal's canonical `IntentPublished`. An indexer
     *        that sees `false` must reconstruct intent2 from the committed order rather than wait for it.
     */
    event IntentChained(
        bytes32 indexed intentHash,
        address indexed vault,
        address indexed token,
        uint256 amountIn,
        uint256 amountOut,
        bool published
    );

    // ============ Errors ============

    /// @notice `order.portal` is zero or has no deployed code. This is not Portal identity attestation.
    error InvalidPortal();

    /// @notice The reward does not carry exactly one leg.
    error InvalidRewardLegCount(uint256 count);

    /// @notice The reward leg names a token this contract did not measure.
    error RewardTokenMismatch(address expected, address actual);

    /// @notice The reward declares a native amount. Native rewards are out of scope; see the contract NatSpec.
    error NativeRewardNotSupported();

    /// @notice Nothing was measured -- intent1's earlier calls delivered no `token` to this contract.
    error ZeroAmount();

    /// @notice The measured amount is below the order's floor.
    error AmountBelowFloor(uint256 amountIn, uint256 minAmountIn);

    /// @notice {Order.scale} is zero, which would oblige the solver to deliver nothing.
    error InvalidScale();

    /// @notice Intent2's reward deadline is in the past or inside {MIN_DEADLINE_BUFFER}.
    error DeadlineTooSoon(uint64 deadline, uint256 timestamp);

    /// @notice The transfer moved less into the vault than was declared, e.g. a fee-on-transfer token.
    error PushShortfall(address vault, uint256 expected, uint256 delivered);

    /// @notice Intent2's hash has already withdrawn or refunded, so no claimant can be paid from it.
    /// @dev FAIL-FAST, not fund protection. The distinction is easy to get backwards and worth stating.
    ///
    ///      A push into a settled vault is NOT stranded. `refund()` is permissionless; while a proof
    ///      stands `_validateRefund` reverts only on `Initial` and `Funded`, so `Withdrawn` and `Refunded`
    ///      fall through; and `Vault.refund` pays the vault's LIVE balance -- not a recorded amount -- to
    ///      `reward.creator`. The money comes back. It comes back to the creator rather than a claimant,
    ///      and only once someone calls refund.
    ///
    ///      Refusing is still right here, because refusing costs nothing: `chain` runs as intent1's last
    ///      route call, so this revert unwinds the swap along with it. No balance is ever left at rest and
    ///      nothing is bound to the order. Cheaper to refuse outright than to complete and leave the
    ///      creator chasing a refund for an intent that can never pay a claimant.
    ///
    ///      That reasoning is load-bearing on atomicity, so do not port the check by analogy. Where the
    ///      measured balance is already at rest in order-scoped custody with this call as its only exit,
    ///      refusing strands exactly what it looks like it protects.
    error IntentAlreadySettled(bytes32 intentHash, IIntentSource.Status status);

    // ============ External Functions ============

    /**
     * @notice Measure one token balance, escrow it for a second intent, and optionally publish that intent.
     * @dev Render nested templates and resolve/check the LOCAL vault before any value moves. Optional
     *      publication also precedes the transfer. Every validation failure reverts the outer intent
     *      whole. Remote recipients are populated route data for a later fulfillment; chain itself
     *      performs no remote transfer or CCTP burn.
     *
     *      Child-salt uniqueness is the builder's responsibility. Distinct parents may deliberately
     *      resolve to the same unsettled child: its vault may already hold any balance. A new push does
     *      not increase that child's declared reward or delivery obligation. Only this contract's
     *      measured balance sets the new amounts; existing vault balances are not swept or counted.
     *      Parent replay is independently rejected by Inbox, and terminal children remain rejected here.
     * @param order The committed intent2 template. See {Order}.
     * @return intentHash Intent2's hash.
     * @return vault Intent2's vault, credited with at least the measured amount in addition to any prefunding.
     * @return amountIn The measured amount, escrowed as intent2's reward.
     * @return amountOut The scaled destination obligation available to template amount items.
     */
    function chain(
        Order calldata order
    )
        external
        nonReentrant
        returns (
            bytes32 intentHash,
            address vault,
            uint256 amountIn,
            uint256 amountOut
        )
    {
        _validate(order);

        (amountIn, amountOut) = _measure(order);

        Reward memory reward = order.reward;
        reward.tokens[0].amount = amountIn;

        bytes memory route = IntentTemplate.render(
            order.template,
            amountIn,
            amountOut
        );
        IIntentSource portal = IIntentSource(order.portal);

        // Resolved WITHOUT publishing. `publish` returns the vault too, but making the flag optional means
        // neither the address nor the settled check may depend on it.
        (intentHash, , ) = portal.getIntentHash(
            order.destination,
            route,
            reward
        );
        vault = portal.intentVaultAddress(order.destination, route, reward);

        _requireNotSettled(portal, intentHash);

        if (order.publish) {
            portal.publish(order.destination, route, reward);
        }

        _pushAndVerify(order.token, vault, amountIn);

        emit IntentChained(
            intentHash,
            vault,
            order.token,
            amountIn,
            amountOut,
            order.publish
        );
    }

    // ============ Internal Functions ============

    /**
     * @notice Reject a hash that has already withdrawn or refunded.
     * @dev `IntentSource._validatePublish` refuses `Withdrawn` and `Refunded`, and inheriting that side
     *      effect would leave the terminal case unchecked whenever `order.publish` is false. Asserted
     *      directly instead, so the behaviour does not depend on the flag. What that buys is a fail-fast
     *      revert, not fund protection -- see {IntentAlreadySettled} for why the difference matters.
     *      Initial and Funded children may receive additional pushes; builders are responsible for
     *      distinct child identities when required.
     * @param portal The Portal to ask.
     * @param intentHash Intent2's hash.
     */
    function _requireNotSettled(
        IIntentSource portal,
        bytes32 intentHash
    ) internal view {
        IIntentSource.Status status = portal.getRewardStatus(intentHash);

        if (
            status != IIntentSource.Status.Initial &&
            status != IIntentSource.Status.Funded
        ) {
            revert IntentAlreadySettled(intentHash, status);
        }
    }

    /**
     * @notice Move the measured balance into intent2's vault and verify this transfer's delivery.
     * @dev Prefunding is allowed. Comparing the balance DELTA, not the absolute balance, prevents an
     *      existing balance from masking a fee-on-transfer shortfall. No assumption of an empty or fresh
     *      vault is made, and a vault's previous balance does not change the templated amounts.
     * @param token The measured token.
     * @param vault Intent2's vault.
     * @param amountIn The amount to push.
     */
    function _pushAndVerify(
        address token,
        address vault,
        uint256 amountIn
    ) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(vault);
        IERC20(token).safeTransfer(vault, amountIn);

        uint256 delivered = IERC20(token).balanceOf(vault) - balanceBefore;
        if (delivered < amountIn) {
            revert PushShortfall(vault, amountIn, delivered);
        }
    }

    /**
     * @notice Measure the held balance and derive the two amounts intent2 is built from.
     * @param order The validated order.
     * @return amountIn The measured balance, escrowed as intent2's reward.
     * @return amountOut The scaled destination obligation.
     */
    function _measure(
        Order calldata order
    ) internal view returns (uint256 amountIn, uint256 amountOut) {
        amountIn = IERC20(order.token).balanceOf(address(this));

        if (amountIn == 0) {
            revert ZeroAmount();
        }
        if (amountIn < order.minAmountIn) {
            revert AmountBelowFloor(amountIn, order.minAmountIn);
        }

        amountOut = _calculateAmountOut(amountIn, order.scale);
    }

    /**
     * @notice Calculate the destination obligation separately from balance measurement.
     * @dev Ceil rounding serves two purposes. It rounds toward the USER, since `amountOut` is the solver's
     *      delivery floor. And it guarantees a non-zero obligation: with `amountIn >= 1` and `scale >= 1`
     *      the quotient is strictly positive, so no order can oblige a solver to deliver nothing while
     *      collecting the whole escrow. That is why there is no zero-obligation check.
     *
     *      {Math-mulDiv} is used for that ROUNDING MODE, not for its wide intermediate, and the distinction
     *      is worth stating because it is easy to get backwards. Precision here is fixed by {WAD} alone --
     *      `ceil(amountIn * scale / WAD)` is one exact integer, and no intermediate width changes it by a
     *      unit. The 512-bit path buys only RANGE, and the range is not close to binding: overflow of a
     *      plain `amountIn * scale` needs the product to reach `2^256`, which on a 6-to-18 lane
     *      (`scale = 1e30`) means an `amountIn` above `1.16e47` -- some seventeen orders of magnitude past
     *      an 18-decimal token with a trillion-unit supply. Under checked arithmetic that case would revert
     *      rather than wrap in any event.
     *
     *      What it does earn is a ceiling with no overflow edge of its own. The hand-rolled form,
     *      `(amountIn * scale + WAD - 1) / WAD`, introduces exactly the boundary overflow the plain
     *      expression does not have; `mulDiv` adds its increment after the division instead.
     * @param amountIn The positive measured balance.
     * @param scale The validated positive WAD-denominated conversion and proportional spread.
     * @return amountOut The ceil-rounded destination obligation. No flat fee is applied.
     */
    function _calculateAmountOut(
        uint256 amountIn,
        uint256 scale
    ) internal pure returns (uint256 amountOut) {
        return Math.mulDiv(amountIn, scale, WAD, Math.Rounding.Ceil);
    }

    /**
     * @notice Rejects a malformed order before anything is measured or moved.
     * @param order The order to validate.
     */
    function _validate(Order calldata order) internal view {
        if (order.portal == address(0) || order.portal.code.length == 0)
            revert InvalidPortal();
        IntentTemplate.validateShape(order.template.route);

        // A zero scale would publish an intent obliging the solver to deliver nothing while still
        // collecting the whole escrow.
        if (order.scale == 0) {
            revert InvalidScale();
        }

        // This contract funds and verifies exactly one leg, in the measured token. Arbitrary prefunding
        // is allowed, but cannot establish delivery of an additional reward leg through this call.
        if (order.reward.tokens.length != 1) {
            revert InvalidRewardLegCount(order.reward.tokens.length);
        }
        if (order.reward.tokens[0].token != order.token) {
            revert RewardTokenMismatch(
                order.token,
                order.reward.tokens[0].token
            );
        }

        // A native reward would make this contract's own funding path payable and drag in the NATIVE_ERC20
        // alias guard, `Vault.withdraw`'s `NativeTransferFailed` revert against a contract claimant, and
        // `Vault.refund`'s discarded native call. None of it is needed for a token-in/token-out chain.
        if (order.reward.nativeAmount != 0) {
            revert NativeRewardNotSupported();
        }

        if (order.reward.deadline < block.timestamp + MIN_DEADLINE_BUFFER) {
            revert DeadlineTooSoon(order.reward.deadline, block.timestamp);
        }
    }
}
