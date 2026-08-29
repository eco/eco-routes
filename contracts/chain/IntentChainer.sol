/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IIntentSource} from "../interfaces/IIntentSource.sol";
import {Reward} from "../types/Intent.sol";

/**
 * @title IntentChainer
 * @notice Publishes a second intent whose amount is not known until the first intent executes.
 * @dev Called as the last {Call} of an executing intent (intent1), at which point this contract holds the
 *      output of whatever intent1's earlier calls produced -- typically a DEX swap that named this contract
 *      as its recipient. It measures that balance -- the ONE runtime measurement in the whole flow -- and
 *      derives from it the two amounts of a second intent (intent2) whose every other field was fixed when
 *      intent1 was signed: `amountIn` is escrowed as intent2's reward, and `amountIn * scale` is written
 *      into the route as what intent2's solver must deliver. The gap between them is that solver's margin,
 *      and `scale` also carries the source-to-destination unit conversion -- which is NOT the identity for
 *      the same token across chains.
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
 *      WHY `publish` IS UNCONDITIONAL. It does three jobs at once: it returns intent2's vault address (which
 *      cannot be derived here -- the Portal's vault implementation is a `private immutable` with no getter),
 *      it emits the only event carrying intent2's route as complete bytes plus every {Reward} field, and it
 *      rejects a hash that has already settled. Funding is deliberately NOT called: `IntentSource._fundToken`
 *      returns early once `balanceOf(vault) >= amount`, and `_validateWithdraw` accepts `Status.Initial`, so a
 *      pushed-but-unfunded intent is fully withdrawable by the proven claimant.
 */
contract IntentChainer is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Types ============

    /**
     * @notice A position in intent2's route bytes that receives the destination amount.
     * @dev Every slot receives the SAME scalar, `ceil(amountIn * scale / WAD)`. That is what the
     *      solver of intent2 must supply on the destination, and it appears once as
     *      `route.tokens[0].amount` and again inside any
     *      call that moves it (the `transfer(swapper, ...)` that feeds a destination swap). Because both
     *      want the identical number, no per-slot discriminator is needed. Width and byte order are the
     *      destination VM's, not this chain's: an EVM route carries `abi.encode`d 32-byte big-endian words,
     *      while a Solana route carries Borsh 8-byte little-endian u64s.
     * @param width Bytes written, 1..32. A value that does not fit reverts rather than truncating.
     * @param littleEndian True for Borsh/Solana byte order, false for EVM big-endian words.
     */
    struct Slot {
        uint8 width;
        bool littleEndian;
    }

    /**
     * @notice A fully committed intent2, minus the one amount that does not exist yet.
     * @dev The route is carried as literal SEGMENTS surrounding the {Slot} positions rather than as whole
     *      bytes plus numeric offsets. The route is rebuilt by concatenation --
     *      `segments[0] ‖ enc(slots[0]) ‖ segments[1] ‖ ... ‖ segments[n]` -- so a mis-stated write position
     *      is not expressible, and the same encoding serves an EVM destination and a Borsh one without this
     *      contract knowing which it is holding.
     * @param token The single ERC20 measured here, escrowed as intent2's reward.
     * @param destination Intent2's destination chain id.
     * @param segments Literal route bytes between slots. MUST be `slots.length + 1` entries; the first and
     *        last may be empty.
     * @param slots Positions receiving the measured amount, in route order.
     * @param reward Intent2's reward. MUST carry exactly one leg, in `token`, with no native amount; the
     *        leg's `amount` field is ignored on input and overwritten with the measured amount.
     * @param scale The ENTIRE source-to-destination transform, {WAD}-denominated:
     *        `amountOut = ceil(amountIn * scale / WAD)`. It carries both the unit conversion and intent2's
     *        solver spread, because those compose into one ratio and there is no reason to commit two
     *        numbers where one will do.
     *
     *        THE UNIT PART exists because "the same token" does not mean the same UNIT across chains. USDC
     *        is 6 decimals on Ethereum, Base and Solana, but Binance-Peg USDC on BNB Chain is 18, and Arc's
     *        native USDC is 18 against a 6-decimal ERC20 wrapper (see {DepositAddress_CCTPMint_Arc}'s
     *        `NATIVE_USDC_SCALING`).
     *
     *        The denominator is DECIMAL on purpose. Unit conversions are powers of ten, so a decimal
     *        denominator represents every one of them exactly in both directions, where a binary
     *        denominator (Q128 and friends) cannot: 6-to-18 is `1e30`, 18-to-6 is `1e6`, and a same-unit
     *        lane is `WAD`, all integers. A spread multiplies in: same units less 50bps is `0.995e18`.
     *
     *        THE SPREAD PART is PROPORTIONAL, not flat. The reward leg escrows the whole measured
     *        `amountIn` while the route obliges only `amountIn * scale`, so the difference is the solver's
     *        entire margin, and it grows with the amount. That is a deliberate trade: a flat fee would
     *        price destination gas independently of size, but it cannot be folded into a ratio, and the
     *        only thing that moves `amountIn` here is swap slippage -- a percent or so around a known
     *        expectation -- over which the two are indistinguishable. Use `minAmountIn` to express "too
     *        small to be worth filling"; it says that directly, where a flat fee only said it by accident.
     *
     *        Rounding is toward the USER (up), because this value is the solver's delivery FLOOR --
     *        rounding it down would quietly shave the last unit off what the user receives on every
     *        downscaling lane.
     * @param minAmountIn Floor on the measured amount. Reverts below it, so a swap that under-delivered
     *        unwinds intent1 rather than publishing an intent nobody will fill.
     */
    struct Order {
        address token;
        uint64 destination;
        bytes[] segments;
        Slot[] slots;
        Reward reward;
        uint256 scale;
        uint256 minAmountIn;
    }

    // ============ Constants ============

    /// @notice Fixed-point denominator for {Order.scale}.
    /// @dev Decimal, not binary, so every power-of-ten unit conversion is exact in both directions. Matches
    ///      the WAD convention v3 adopts for `RewardToken.rate`.
    uint256 public constant WAD = 1e18;

    /// @notice Upper bound on slots per order, bounding the concatenation loop's gas.
    uint256 public constant MAX_SLOTS = 8;

    /// @notice Minimum time intent2's reward deadline must clear `block.timestamp` by.
    /// @dev Intent2's deadlines are fixed when intent1 is signed, but intent1 may be fulfilled at any point
    ///      up to its own route deadline. Publishing an intent2 that is already expired is recoverable (the
    ///      escrow refunds to `reward.creator` after the deadline) but burns intent1 for nothing, so it fails
    ///      loudly here instead.
    uint64 public constant MIN_DEADLINE_BUFFER = 5 minutes;

    // ============ Immutables ============

    /// @notice The Portal this contract publishes intent2 to. Also the Portal whose Executor calls in.
    IIntentSource public immutable PORTAL;

    // ============ Events ============

    /**
     * @notice A second intent was published and funded from a measured balance.
     * @param intentHash Intent2's hash.
     * @param vault Intent2's deterministic vault, which now holds `amountIn`.
     * @param token The measured token.
     * @param amountIn The measured amount, escrowed as intent2's reward.
     * @param amountOut The scaled destination obligation, written to every route slot.
     */
    event IntentChained(
        bytes32 indexed intentHash,
        address indexed vault,
        address indexed token,
        uint256 amountIn,
        uint256 amountOut
    );

    // ============ Errors ============

    /// @notice The Portal address was zero.
    error InvalidPortal();

    /// @notice `segments.length` is not `slots.length + 1`.
    error SegmentCountMismatch(uint256 segments, uint256 slots);

    /// @notice `slots.length` exceeds {MAX_SLOTS}.
    error TooManySlots(uint256 count, uint256 max);

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

    /// @notice A slot width is zero or above 32.
    error InvalidSlotWidth(uint8 width);

    /// @notice The measured amount does not fit the slot, e.g. a Solana u64 slot and an 18-decimal amount.
    error AmountExceedsSlotWidth(uint256 amount, uint8 width);

    /// @notice Intent2's reward deadline is in the past or inside {MIN_DEADLINE_BUFFER}.
    error DeadlineTooSoon(uint64 deadline, uint256 timestamp);

    /// @notice The transfer moved less into the vault than was declared, e.g. a fee-on-transfer token.
    error PushShortfall(address vault, uint256 expected, uint256 delivered);

    /// @notice Intent2's vault already holds at least the amount being pushed.
    /// @dev A salt collision: the same order resolving to a hash that has already been chained. Nothing
    ///      legitimate pre-funds this address, since it depends on the measured amount. See
    ///      {_pushAndVerify} for why `publish` does not catch this on its own.
    error VaultAlreadyFunded(address vault, uint256 balance);

    // ============ Constructor ============

    /**
     * @notice Binds this contract to one Portal.
     * @param portal The Portal to publish intent2 to.
     */
    constructor(address portal) {
        if (portal == address(0)) {
            revert InvalidPortal();
        }

        PORTAL = IIntentSource(portal);
    }

    // ============ External Functions ============

    /**
     * @notice Measure this contract's balance of one token and publish a second intent escrowing it.
     * @dev Ordering is load-bearing. The route is built and `publish` is called BEFORE any value moves, so
     *      every validation failure reverts intent1 whole rather than stranding tokens in a vault that
     *      cannot pay out. `publish` also hands back the vault address, which is why it runs before the
     *      transfer rather than after.
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
     * @return amountOut The scaled destination obligation written to every slot.
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

        (intentHash, vault) = PORTAL.publish(
            order.destination,
            _buildRoute(order, amountOut),
            reward
        );

        _pushAndVerify(order.token, vault, amountIn);

        emit IntentChained(intentHash, vault, order.token, amountIn, amountOut);
    }

    // ============ Internal Functions ============

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
        uint256 slotCount = order.slots.length;

        if (slotCount > MAX_SLOTS) {
            revert TooManySlots(slotCount, MAX_SLOTS);
        }
        if (order.segments.length != slotCount + 1) {
            revert SegmentCountMismatch(order.segments.length, slotCount);
        }

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

    /**
     * @notice Rebuild intent2's route bytes, splicing the destination amount into every slot.
     * @dev Concatenation, not overwriting: the caller commits the bytes AROUND each amount rather than an
     *      offset INTO a blob, so there is no arithmetic that can land a write on a Borsh vector length, an
     *      SPL account pubkey, or an ABI tail offset.
     * @param order The order supplying segments and slots.
     * @param amountOut The destination amount to write into every slot.
     * @return route The route bytes to publish.
     */
    function _buildRoute(
        Order calldata order,
        uint256 amountOut
    ) internal pure returns (bytes memory route) {
        uint256 slotCount = order.slots.length;

        // `bytes.concat` reallocates and copies the whole accumulated route on every iteration, so this is
        // quadratic in segment count. {MAX_SLOTS} is what keeps that acceptable -- at most eight copies of a
        // route that is itself small. Raising the bound means revisiting this loop, not just the constant.
        route = order.segments[0];
        for (uint256 i = 0; i < slotCount; ++i) {
            route = bytes.concat(
                route,
                _encodeAmount(amountOut, order.slots[i]),
                order.segments[i + 1]
            );
        }
    }

    /**
     * @notice Encode the measured amount for one slot's width and byte order.
     * @dev Reverts rather than truncating when the value does not fit. Silent truncation is the dangerous
     *      case: an amount wrapped into a Solana u64 would publish an intent2 that is well-formed, fillable
     *      and pays out a fraction of what was escrowed.
     * @param amount The value to encode.
     * @param slot The slot's width and byte order.
     * @return out Exactly `slot.width` bytes.
     */
    function _encodeAmount(
        uint256 amount,
        Slot calldata slot
    ) internal pure returns (bytes memory out) {
        uint8 width = slot.width;

        if (width == 0 || width > 32) {
            revert InvalidSlotWidth(width);
        }
        if (width < 32 && amount >> (uint256(width) * 8) != 0) {
            revert AmountExceedsSlotWidth(amount, width);
        }

        out = new bytes(width);
        for (uint256 i = 0; i < width; ++i) {
            // casting to 'uint8' is safe because truncation to the low byte IS the operation -- the
            // fits-in-width check above already rejected every value with a set bit above `width` bytes.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 byteValue = uint8(amount >> (8 * i));
            out[slot.littleEndian ? i : width - 1 - i] = bytes1(byteValue);
        }
    }
}
