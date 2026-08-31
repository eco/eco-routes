/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "../BaseTest.sol";
import {IntentChainer} from "../../contracts/chain/IntentChainer.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {Call, Reward, Route, TokenAmount} from "../../contracts/types/Intent.sol";
import {TestERC20} from "../../contracts/test/TestERC20.sol";

/**
 * @notice Stands in for a DEX: holds an output inventory and pays it to a named recipient.
 * @dev The Executor transfers the input in first, then calls {swap}, mirroring how a real route feeds a
 *      router before invoking it.
 */
contract MockSwapper {
    function swap(address tokenOut, uint256 amountOut, address to) external {
        IERC20(tokenOut).transfer(to, amountOut);
    }
}

contract IntentChainerTest is BaseTest {
    IntentChainer internal chainer;
    MockSwapper internal swapper;
    address internal solver;

    uint64 internal constant DEST_CHAIN = 8453;
    uint256 internal constant SWAP_IN = 1000e6;
    uint256 internal constant SWAP_OUT = 990e6;
    /// @dev A same-unit lane less a 100bps solver spread. 990e6 * 0.99 == 980.1e6 exactly.
    uint256 internal constant SPREAD = 0.99e18;
    uint256 internal constant SWAP_NET = 980_100_000;
    bytes32 internal constant MARKER = bytes32(type(uint256).max);
    uint256 internal constant WAD = 1e18;

    function setUp() public override {
        super.setUp();

        chainer = new IntentChainer();
        swapper = new MockSwapper();
        solver = makeAddr("solver");

        tokenB.mint(address(swapper), SWAP_OUT * 10);
    }

    // ============ Integration: driven through a real fulfillment ============

    /**
     * @notice The whole chain: a solver fulfils intent1, whose calls swap into the chainer and then invoke
     *         it; the chainer publishes intent2 and pushes the swap output into intent2's vault.
     */
    function test_chain_publishesAndFundsIntentTwoThroughFulfill() public {
        IntentChainer.Order memory order = _evmOrder(SPREAD, 0);

        Route memory route1 = _intentOneRoute(order);
        Reward memory reward1 = _intentOneReward();
        uint64 destination1 = uint64(block.chainid);

        bytes32 routeHash1 = keccak256(abi.encode(route1));
        bytes32 rewardHash1 = keccak256(abi.encode(reward1));
        bytes32 intentHash1 = keccak256(
            abi.encodePacked(destination1, routeHash1, rewardHash1)
        );

        (bytes32 expectedHash2, ) = _expectedIntentTwo(SWAP_OUT, SWAP_NET);
        address vault2 = _expectedVaultTwo();

        tokenA.mint(solver, SWAP_IN);
        vm.startPrank(solver);
        tokenA.approve(address(portal), SWAP_IN);
        portal.fulfill(
            intentHash1,
            route1,
            rewardHash1,
            bytes32(uint256(uint160(claimant)))
        );
        vm.stopPrank();

        assertEq(
            tokenB.balanceOf(vault2),
            SWAP_OUT,
            "intent2 vault holds the full measured amount"
        );
        assertEq(
            tokenB.balanceOf(address(chainer)),
            0,
            "chainer keeps no residue"
        );
        assertEq(
            uint8(portal.getRewardStatus(expectedHash2)),
            uint8(IIntentSource.Status.Initial),
            "publish-only leaves intent2 at Initial"
        );
    }

    // ============ Amount population ============

    function test_chain_writesAmountInToRewardAndAmountOutToSlots() public {
        IntentChainer.Order memory order = _evmOrder(SPREAD, 0);
        tokenB.mint(address(chainer), SWAP_OUT);

        (bytes32 expectedHash, ) = _expectedIntentTwo(SWAP_OUT, SWAP_NET);

        (bytes32 intentHash, , uint256 amountIn, uint256 amountOut) = chainer
            .chain(order);

        assertEq(amountIn, SWAP_OUT, "reward leg escrows the measured amount");
        assertEq(amountOut, SWAP_NET, "route legs carry the scaled amount");
        assertEq(
            intentHash,
            expectedHash,
            "published intent2 matches the amount-substituted template"
        );
    }

    // ============ Unit scaling ============

    /**
     * @notice A 6-to-18 decimal lane (e.g. Base USDC to Binance-Peg USDC) scales the obligation exactly.
     */
    function test_chain_scalesUpAcrossADecimalMismatch() public {
        IntentChainer.Order memory order = _evmOrder(1e30, 0); // 1e12 * WAD
        tokenB.mint(address(chainer), SWAP_OUT);

        (, , uint256 amountIn, uint256 amountOut) = chainer.chain(order);

        assertEq(amountIn, SWAP_OUT, "reward stays in source units");
        assertEq(
            amountOut,
            SWAP_OUT * 1e12,
            "obligation is expressed in 18-decimal units"
        );
    }

    /**
     * @notice An 18-to-6 lane scales down exactly -- no dust lost to a binary denominator.
     */
    function test_chain_scalesDownAcrossADecimalMismatch() public {
        uint256 measured = 3e18;

        IntentChainer.Order memory order = _evmOrder(1e6, 0); // WAD / 1e12
        tokenB.mint(address(chainer), measured);

        (, , uint256 amountIn, uint256 amountOut) = chainer.chain(order);

        assertEq(amountIn, measured, "reward stays in source units");
        assertEq(amountOut, 3e6, "exact down-conversion, no truncation");
    }

    /**
     * @notice Scaling rounds toward the user, since the written value is the solver's delivery floor.
     */
    function test_chain_scalingRoundsInTheUsersFavour() public {
        IntentChainer.Order memory order = _evmOrder(1e6, 0); // WAD / 1e12
        tokenB.mint(address(chainer), 3e18 + 1); // one wei past an exact conversion

        (, , , uint256 amountOut) = chainer.chain(order);

        assertEq(amountOut, 3e6 + 1, "a partial unit rounds up, not away");
    }

    /**
     * @notice A unit conversion and a solver spread compose into the single scale.
     * @dev 6-to-18 decimals (1e12) less 100bps, expressed as one number.
     */
    function test_chain_scaleCarriesUnitsAndSpreadTogether() public {
        IntentChainer.Order memory order = _evmOrder((1e30 * 99) / 100, 0);
        tokenB.mint(address(chainer), SWAP_OUT);

        (, , uint256 amountIn, uint256 amountOut) = chainer.chain(order);

        assertEq(amountIn, SWAP_OUT, "reward escrows the whole measurement");
        assertEq(
            amountOut,
            SWAP_NET * 1e12,
            "one scale expresses both the unit change and the spread"
        );
    }

    function test_chain_revertsOnZeroScale() public {
        IntentChainer.Order memory order = _evmOrder(0, 0);
        tokenB.mint(address(chainer), SWAP_OUT);

        vm.expectRevert(IntentChainer.InvalidScale.selector);
        chainer.chain(order);
    }

    /**
     * @notice The obligation can never round to zero, however extreme the down-conversion.
     * @dev This is why there is no explicit zero-obligation check in the contract: with `amountIn >= 1`
     *      and `scale >= 1` the ceil-rounded quotient is always at least 1, so a solver can never be
     *      obliged to deliver nothing while collecting the whole escrow.
     */
    function test_chain_obligationNeverRoundsToZero() public {
        IntentChainer.Order memory order = _evmOrder(1, 0); // most extreme down-conversion expressible
        tokenB.mint(address(chainer), 1); // and the smallest possible measurement

        (, , , uint256 amountOut) = chainer.chain(order);

        assertEq(amountOut, 1, "ceil floors the obligation at one unit");
    }

    function test_chain_littleEndianSlotWritesBorshByteOrder() public {
        uint256 amount = 0x0102;
        uint256 scale = WAD;

        bytes[] memory segments = new bytes[](2);
        segments[0] = hex"aabbcc";
        segments[1] = hex"ddee";

        IntentChainer.Slot[] memory slots = new IntentChainer.Slot[](1);
        slots[0] = IntentChainer.Slot({width: 8, littleEndian: true});

        IntentChainer.Order memory order = _order(segments, slots, scale, 0);
        tokenB.mint(address(chainer), amount);

        bytes memory expectedRoute = abi.encodePacked(
            segments[0],
            hex"0201000000000000",
            segments[1]
        );
        bytes32 expectedHash = keccak256(
            abi.encodePacked(
                DEST_CHAIN,
                keccak256(expectedRoute),
                keccak256(abi.encode(_rewardWithAmount(amount)))
            )
        );

        (bytes32 intentHash, , , ) = chainer.chain(order);

        assertEq(
            intentHash,
            expectedHash,
            "u64 slot written little-endian, segments preserved verbatim"
        );
    }

    function test_chain_revertsWhenAmountExceedsSlotWidth() public {
        bytes[] memory segments = new bytes[](2);
        segments[0] = hex"aa";
        segments[1] = hex"bb";

        IntentChainer.Slot[] memory slots = new IntentChainer.Slot[](1);
        slots[0] = IntentChainer.Slot({width: 8, littleEndian: true});

        uint256 tooBig = uint256(type(uint64).max) + 1;
        IntentChainer.Order memory order = _order(segments, slots, WAD, 0);
        tokenB.mint(address(chainer), tooBig);

        vm.expectRevert(
            abi.encodeWithSelector(
                IntentChainer.AmountExceedsSlotWidth.selector,
                tooBig,
                uint8(8)
            )
        );
        chainer.chain(order);
    }

    function test_chain_revertsOnZeroWidthSlot() public {
        bytes[] memory segments = new bytes[](2);
        segments[0] = hex"aa";
        segments[1] = hex"bb";

        IntentChainer.Slot[] memory slots = new IntentChainer.Slot[](1);
        slots[0] = IntentChainer.Slot({width: 0, littleEndian: false});

        IntentChainer.Order memory order = _order(segments, slots, WAD, 0);
        tokenB.mint(address(chainer), SWAP_OUT);

        vm.expectRevert(
            abi.encodeWithSelector(
                IntentChainer.InvalidSlotWidth.selector,
                uint8(0)
            )
        );
        chainer.chain(order);
    }

    // ============ Measurement guards ============

    function test_chain_revertsOnZeroBalance() public {
        IntentChainer.Order memory order = _evmOrder(SPREAD, 0);

        vm.expectRevert(IntentChainer.ZeroAmount.selector);
        chainer.chain(order);
    }

    function test_chain_revertsBelowFloor() public {
        IntentChainer.Order memory order = _evmOrder(SPREAD, SWAP_OUT + 1);
        tokenB.mint(address(chainer), SWAP_OUT);

        vm.expectRevert(
            abi.encodeWithSelector(
                IntentChainer.AmountBelowFloor.selector,
                SWAP_OUT,
                SWAP_OUT + 1
            )
        );
        chainer.chain(order);
    }

    // ============ Template validation ============

    function test_chain_revertsOnSegmentCountMismatch() public {
        IntentChainer.Order memory order = _evmOrder(SPREAD, 0);

        bytes[] memory short = new bytes[](order.segments.length - 1);
        for (uint256 i = 0; i < short.length; ++i) {
            short[i] = order.segments[i];
        }
        order.segments = short;

        vm.expectRevert(
            abi.encodeWithSelector(
                IntentChainer.SegmentCountMismatch.selector,
                short.length,
                order.slots.length
            )
        );
        chainer.chain(order);
    }

    function test_chain_revertsOnRewardTokenMismatch() public {
        IntentChainer.Order memory order = _evmOrder(SPREAD, 0);
        order.reward.tokens[0].token = address(tokenA);

        vm.expectRevert(
            abi.encodeWithSelector(
                IntentChainer.RewardTokenMismatch.selector,
                address(tokenB),
                address(tokenA)
            )
        );
        chainer.chain(order);
    }

    function test_chain_revertsOnNativeReward() public {
        IntentChainer.Order memory order = _evmOrder(SPREAD, 0);
        order.reward.nativeAmount = 1;

        vm.expectRevert(IntentChainer.NativeRewardNotSupported.selector);
        chainer.chain(order);
    }

    function test_chain_revertsOnStaleDeadline() public {
        IntentChainer.Order memory order = _evmOrder(SPREAD, 0);
        order.reward.deadline = uint64(block.timestamp + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IntentChainer.DeadlineTooSoon.selector,
                uint64(block.timestamp + 1),
                block.timestamp
            )
        );
        chainer.chain(order);
    }

    // ============ Fixtures ============

    /// @notice Intent2's reward: one tokenB leg whose amount the chainer overwrites.
    function _rewardWithAmount(
        uint256 amount
    ) internal view returns (Reward memory) {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(tokenB), amount: amount});

        return
            Reward({
                deadline: uint64(block.timestamp + 1 days),
                creator: creator,
                prover: address(prover),
                nativeAmount: 0,
                tokens: tokens
            });
    }

    /// @notice Intent2's EVM route, with `amountOut` in both the token leg and the swapper transfer.
    function _intentTwoRoute(
        uint256 amountOut
    ) internal view returns (Route memory) {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(tokenB), amount: amountOut});

        Call[] memory routeCalls = new Call[](1);
        routeCalls[0] = Call({
            target: address(tokenB),
            data: abi.encodeWithSelector(
                IERC20.transfer.selector,
                address(swapper),
                amountOut
            ),
            value: 0
        });

        return
            Route({
                salt: bytes32(uint256(0xC0FFEE)),
                deadline: uint64(block.timestamp + 1 days),
                portal: address(portal),
                nativeAmount: 0,
                tokens: tokens,
                calls: routeCalls
            });
    }

    /// @notice The intent2 hash and route bytes a correct substitution must produce.
    function _expectedIntentTwo(
        uint256 amountIn,
        uint256 amountOut
    ) internal view returns (bytes32 intentHash, bytes memory routeBytes) {
        routeBytes = abi.encode(_intentTwoRoute(amountOut));
        intentHash = keccak256(
            abi.encodePacked(
                DEST_CHAIN,
                keccak256(routeBytes),
                keccak256(abi.encode(_rewardWithAmount(amountIn)))
            )
        );
    }

    /**
     * @notice Build an EVM-destination order the way an SDK would: encode the route with a sentinel in
     *         every runtime position, then split the blob on that sentinel into literal segments.
     */
    function _evmOrder(
        uint256 scale,
        uint256 minAmountIn
    ) internal view returns (IntentChainer.Order memory) {
        bytes memory marked = abi.encode(_intentTwoRoute(uint256(MARKER)));
        bytes[] memory segments = _splitOnMarker(marked);

        IntentChainer.Slot[] memory slots = new IntentChainer.Slot[](
            segments.length - 1
        );
        for (uint256 i = 0; i < slots.length; ++i) {
            slots[i] = IntentChainer.Slot({width: 32, littleEndian: false});
        }

        return _order(segments, slots, scale, minAmountIn);
    }

    function _order(
        bytes[] memory segments,
        IntentChainer.Slot[] memory slots,
        uint256 scale,
        uint256 minAmountIn
    ) internal view returns (IntentChainer.Order memory) {
        return
            IntentChainer.Order({
                publish: true,
                portal: address(portal),
                token: address(tokenB),
                destination: DEST_CHAIN,
                segments: segments,
                slots: slots,
                reward: _rewardWithAmount(0),
                scale: scale,
                minAmountIn: minAmountIn
            });
    }

    /// @notice Split an encoded route on every 32-byte window equal to {MARKER}.
    function _splitOnMarker(
        bytes memory blob
    ) internal pure returns (bytes[] memory segments) {
        uint256[] memory positions = new uint256[](8);
        uint256 found;

        for (uint256 i = 0; i + 32 <= blob.length; ++i) {
            bytes32 word;
            /// @solidity memory-safe-assembly
            assembly {
                word := mload(add(add(blob, 0x20), i))
            }
            if (word == MARKER) {
                positions[found++] = i;
                i += 31;
            }
        }

        segments = new bytes[](found + 1);
        uint256 cursor;
        for (uint256 s = 0; s < found; ++s) {
            segments[s] = _slice(blob, cursor, positions[s] - cursor);
            cursor = positions[s] + 32;
        }
        segments[found] = _slice(blob, cursor, blob.length - cursor);
    }

    function _slice(
        bytes memory blob,
        uint256 start,
        uint256 length
    ) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i = 0; i < length; ++i) {
            out[i] = blob[start + i];
        }
    }

    /// @notice Intent1: swap tokenA into tokenB at the chainer, then invoke the chainer.
    function _intentOneRoute(
        IntentChainer.Order memory order
    ) internal view returns (Route memory) {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(tokenA), amount: SWAP_IN});

        Call[] memory routeCalls = new Call[](3);
        routeCalls[0] = Call({
            target: address(tokenA),
            data: abi.encodeWithSelector(
                IERC20.transfer.selector,
                address(swapper),
                SWAP_IN
            ),
            value: 0
        });
        routeCalls[1] = Call({
            target: address(swapper),
            data: abi.encodeCall(
                MockSwapper.swap,
                (address(tokenB), SWAP_OUT, address(chainer))
            ),
            value: 0
        });
        routeCalls[2] = Call({
            target: address(chainer),
            data: abi.encodeCall(IntentChainer.chain, (order)),
            value: 0
        });

        return
            Route({
                salt: bytes32(uint256(1)),
                deadline: uint64(block.timestamp + 1 days),
                portal: address(portal),
                nativeAmount: 0,
                tokens: tokens,
                calls: routeCalls
            });
    }

    function _intentOneReward() internal view returns (Reward memory) {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(tokenA), amount: SWAP_IN});

        return
            Reward({
                deadline: uint64(block.timestamp + 1 days),
                creator: creator,
                prover: address(prover),
                nativeAmount: 0,
                tokens: tokens
            });
    }

    /// @notice Intent2's vault, predicted from the amount-substituted template.
    function _expectedVaultTwo() internal view returns (address) {
        (, bytes memory routeBytes) = _expectedIntentTwo(SWAP_OUT, SWAP_NET);

        return
            portal.intentVaultAddress(
                DEST_CHAIN,
                routeBytes,
                _rewardWithAmount(SWAP_OUT)
            );
    }
}
