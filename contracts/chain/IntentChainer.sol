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
 * @notice Publishes a second intent whose amount is not known until the first intent executes.
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
     * @notice A second intent was published and funded from a measured balance.
     * @param intentHash Intent2's hash.
     * @param vault Intent2's deterministic vault, which now holds `amountIn`.
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

    /// @notice `order.portal` is the zero address.
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

    /// @notice Intent2's hash has already settled, so a push into its vault could not be paid out.
    /// @dev Checked explicitly rather than inherited from `publish` reverting, because publish is optional.
    error IntentAlreadySettled(bytes32 intentHash, IIntentSource.Status status);

    /// @notice Intent2's vault already holds at least the amount being pushed.
    /// @dev A salt collision: the same order resolving to a hash that has already been chained. Nothing
    ///      legitimate pre-funds this address, since it depends on the measured amount. See
    ///      {_pushAndVerify} for why `publish` does not catch this on its own.
    error VaultAlreadyFunded(address vault, uint256 balance);

    // ============ External Functions ============

    /**
     * @notice Measure this contract's balance of one token and publish a second intent escrowing it.
     * @dev Render nested templates and resolve/check the LOCAL vault before any value moves. Optional
     *      publication also precedes the transfer. Every validation failure reverts the outer intent
     *      whole. Remote recipients are populated route data for a later fulfillment; chain itself
     *      performs no remote transfer or CCTP burn.
     *
     *      `publish` does NOT reject every colliding hash, and the gap is the operating window rather than
     *      an edge: `IntentSource._validatePublish` rejects only `Withdrawn` and `Refunded`, and publishing
     *      an `Initial` or `Funded` intent is deliberately idempotent. Because this contract never calls
     *      `fund`, intent2 sits at `Initial` for its whole useful life -- so a second `chain` on a colliding
     *      order would re-publish and push a second `amountIn` into the same vault, merging two chains into
     *      one intent with no signal. {_pushAndVerify} is what actually closes that.
     * @param order The committed intent2 template. See {Order}.
     * @return intentHash Intent2's hash.
     * @return vault Intent2's vault, now holding the measured amount.
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
     * @notice Reject a hash that has already paid out or refunded.
     * @dev `IntentSource._validatePublish` refuses `Withdrawn` and `Refunded`, and inheriting that side
     *      effect would leave the terminal case unguarded whenever `order.publish` is false. Asserted
     *      directly instead, so the protection holds either way. The `Initial`-state collision -- the one
     *      that actually occurs, since this contract never funds intent2 -- is caught in {_pushAndVerify}.
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
     * @notice Move the measured balance into intent2's vault, bracketing the transfer with the two checks
     *         that make it safe.
     * @dev Reading the vault BEFORE the transfer does the work `publish` cannot. `_validatePublish` lets an
     *      `Initial` intent be re-published, and intent2 is `Initial` for its whole useful life because this
     *      contract never funds it -- so a colliding order would otherwise top the same vault up a second
     *      time, consuming a second intent1 and producing no second delivery. Nothing legitimate can
     *      pre-fund this address: it depends on the measured amount, so it is unknowable until this call
     *      runs. A balance already covering the push therefore means the hash is not fresh.
     *
     *      Comparing a DELTA afterwards, rather than the absolute balance, is what keeps the shortfall check
     *      honest. The vault address is computable by anyone reading intent1's calldata, so an absolute
     *      comparison could be satisfied by a donation instead of by this transfer -- masking exactly the
     *      fee-on-transfer case the check exists to catch.
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
        if (balanceBefore >= amountIn) {
            revert VaultAlreadyFunded(vault, balanceBefore);
        }

        IERC20(token).safeTransfer(vault, amountIn);

        uint256 delivered = IERC20(token).balanceOf(vault) - balanceBefore;
        if (delivered < amountIn) {
            revert PushShortfall(vault, amountIn, delivered);
        }
    }

    /**
     * @notice Measure the held balance and derive the two amounts intent2 is built from.
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

        amountOut = Math.mulDiv(amountIn, order.scale, WAD, Math.Rounding.Ceil);
    }

    /**
     * @notice Rejects a malformed order before anything is measured or moved.
     * @param order The order to validate.
     */
    function _validate(Order calldata order) internal view {
        if (order.portal == address(0)) revert InvalidPortal();
        IntentTemplate.validateShape(order.template.route);

        // A zero scale would publish an intent obliging the solver to deliver nothing while still
        // collecting the whole escrow.
        if (order.scale == 0) {
            revert InvalidScale();
        }

        // Exactly one leg, in the measured token. A leg in any other token could never be funded from here --
        // the vault address is unknowable in advance, so nothing else can pre-fund it -- and once such an
        // intent is proven its vault is bricked: `_validateRefund` reverts `IntentNotClaimed` for as long as
        // the proof stands, while `recoverToken` refuses reward tokens.
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
