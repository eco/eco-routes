/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "../BaseTest.sol";
import {IntentChainer} from "../../contracts/chain/IntentChainer.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {Call, Reward, Route, TokenAmount} from "../../contracts/types/Intent.sol";

/// @notice Stands in for a DEX: pays a fixed output to a named recipient out of its own inventory.
contract IntegrationSwapper {
    function swap(address tokenOut, uint256 amountOut, address to) external {
        IERC20(tokenOut).transfer(to, amountOut);
    }
}

/**
 * @title IntentChainerIntegrationTest
 * @notice End-to-end lifecycle of a chained pair, driven only through real Portal entry points.
 * @dev Every test here starts from a solver calling `portal.fulfill` on intent1 and follows the money all
 *      the way to a `withdraw` or a `refund` on intent2. Nothing calls `chain()` directly.
 */
contract IntentChainerIntegrationTest is BaseTest {
    IntentChainer internal chainer;
    IntegrationSwapper internal swapper;
    address internal solver;
    address internal solver2;

    uint64 internal constant DEST_CHAIN = 8453;
    uint256 internal constant SWAP_IN = 1000e6;
    uint256 internal constant SWAP_OUT = 990e6;
    /// @dev A same-unit lane less a 100bps solver spread. 990e6 * 0.99 == 980.1e6 exactly.
    uint256 internal constant SPREAD = 0.99e18;
    uint256 internal constant SWAP_NET = 980_100_000;
    uint64 internal constant INTENT_TWO_LIFETIME = 2 days;

    /// @dev Pinned at setUp so fixtures stay byte-identical across a `_timeTravel`.
    uint64 internal intentOneDeadline;
    uint64 internal intentTwoDeadline;
    bytes32 internal constant MARKER = bytes32(type(uint256).max);
    uint256 internal constant WAD = 1e18;

    function setUp() public override {
        super.setUp();

        chainer = new IntentChainer();
        swapper = new IntegrationSwapper();
        solver = makeAddr("chainSolver");
        solver2 = makeAddr("chainSolver2");

        tokenB.mint(address(swapper), SWAP_OUT * 20);

        intentOneDeadline = uint64(block.timestamp + 1 days);
        intentTwoDeadline = uint64(block.timestamp + INTENT_TWO_LIFETIME);
    }

    // ============ Full lifecycle ============

    /**
     * @notice Intent1 fulfilled, intent2 published and pushed, proven, then withdrawn by its claimant.
     */
    function test_lifecycle_chainedIntentIsWithdrawableByItsClaimant() public {
        (bytes32 hash2, address vault2) = _runChain(
            bytes32(uint256(1)),
            SPREAD
        );

        assertEq(tokenB.balanceOf(vault2), SWAP_OUT, "vault funded");
        assertTrue(
            portal.isIntentFunded(
                DEST_CHAIN,
                _routeBytes(SWAP_NET),
                _intentTwoReward(SWAP_OUT)
            ),
            "balance-based funded check passes without fund()"
        );

        _addProof(hash2, uint96(DEST_CHAIN), claimant);

        uint256 before = tokenB.balanceOf(claimant);
        portal.withdraw(
            DEST_CHAIN,
            keccak256(_routeBytes(SWAP_NET)),
            _intentTwoReward(SWAP_OUT)
        );

        assertEq(
            tokenB.balanceOf(claimant) - before,
            SWAP_OUT,
            "claimant is paid the full measured amount"
        );
        assertEq(tokenB.balanceOf(vault2), 0, "vault drained");
        assertEq(
            uint8(portal.getRewardStatus(hash2)),
            uint8(IIntentSource.Status.Withdrawn),
            "intent2 settles Withdrawn"
        );
    }

    /**
     * @notice The solver's spread is the gap between what intent2 escrows and what its route obliges.
     */
    function test_lifecycle_spreadIsTheGapBetweenEscrowAndObligation() public {
        (, address vault2) = _runChain(bytes32(uint256(2)), SPREAD);

        Route memory published = abi.decode(_routeBytes(SWAP_NET), (Route));

        assertEq(
            tokenB.balanceOf(vault2),
            SWAP_OUT,
            "escrow is the full measured amount"
        );
        assertEq(
            published.tokens[0].amount,
            SWAP_NET,
            "obligation is net of the spread"
        );
        assertEq(
            tokenB.balanceOf(vault2) - published.tokens[0].amount,
            SWAP_OUT - SWAP_NET,
            "the difference is exactly the spread"
        );
    }

    /**
     * @notice An unsolved intent2 refunds to its creator after the deadline, permissionlessly.
     */
    function test_lifecycle_unsolvedChainedIntentRefundsToCreator() public {
        _runChain(bytes32(uint256(3)), SPREAD);

        _timeTravel(intentTwoDeadline + 1);

        uint256 before = tokenB.balanceOf(creator);
        vm.prank(otherPerson);
        portal.refund(
            DEST_CHAIN,
            keccak256(_routeBytes(SWAP_NET)),
            _intentTwoReward(SWAP_OUT)
        );

        assertEq(
            tokenB.balanceOf(creator) - before,
            SWAP_OUT,
            "creator recovers the whole escrow"
        );
    }

    /**
     * @notice Surplus left in the vault above the declared reward is recoverable, not stranded.
     * @dev A donation to the vault address (or any over-push) sits above `reward.tokens[0].amount`.
     *      `withdraw` pays only the declared amount, and a following `refund` sweeps the remainder to the
     *      creator -- `_validateRefund` passes once the status is no longer Initial/Funded.
     */
    function test_lifecycle_vaultSurplusIsSweptToCreatorAfterWithdraw() public {
        (bytes32 hash2, address vault2) = _runChain(
            bytes32(uint256(4)),
            SPREAD
        );

        uint256 donation = 7e6;
        tokenB.mint(vault2, donation);

        _addProof(hash2, uint96(DEST_CHAIN), claimant);
        portal.withdraw(
            DEST_CHAIN,
            keccak256(_routeBytes(SWAP_NET)),
            _intentTwoReward(SWAP_OUT)
        );

        assertEq(
            tokenB.balanceOf(vault2),
            donation,
            "surplus survives the withdraw"
        );

        uint256 before = tokenB.balanceOf(creator);
        portal.refund(
            DEST_CHAIN,
            keccak256(_routeBytes(SWAP_NET)),
            _intentTwoReward(SWAP_OUT)
        );

        assertEq(
            tokenB.balanceOf(creator) - before,
            donation,
            "surplus reaches the creator"
        );
    }

    // ============ Atomicity ============

    /**
     * @notice A swap that under-delivers unwinds intent1 whole; no partial state survives.
     */
    function test_atomicity_underDeliveredSwapRevertsTheWholeFulfillment()
        public
    {
        IntentChainer.Order memory order = _order(SPREAD, SWAP_OUT + 1);

        uint256 solverBefore = _prepareSolver(solver, SWAP_IN);

        vm.prank(solver);
        vm.expectRevert();
        portal.fulfill(
            _intentOneHash(bytes32(uint256(5)), order),
            _intentOneRoute(bytes32(uint256(5)), order),
            keccak256(abi.encode(_intentOneReward())),
            bytes32(uint256(uint160(claimant)))
        );

        assertEq(
            tokenA.balanceOf(solver),
            solverBefore,
            "solver keeps their input"
        );
        assertEq(
            tokenB.balanceOf(address(chainer)),
            0,
            "chainer holds nothing"
        );
    }

    /**
     * @notice A colliding hash reverts while intent2 is still UNSETTLED -- the state it is normally in.
     * @dev This is the case the settled-hash test below does not reach, and it is the one that actually
     *      occurs. `IntentSource._validatePublish` rejects only `Withdrawn` and `Refunded`; re-publishing an
     *      `Initial` intent is deliberately idempotent, and intent2 is `Initial` for its whole useful life
     *      because the chainer never funds it. So `publish` does not reject this collision -- the vault
     *      balance read before the push does. Without it the second push would top up the same vault,
     *      consuming a second intent1 and producing no second delivery.
     */
    function test_atomicity_collidingHashRevertsWhileIntentTwoIsUnsettled()
        public
    {
        (bytes32 hash2, address vault2) = _runChain(
            bytes32(uint256(10)),
            SPREAD
        );

        assertEq(
            uint8(portal.getRewardStatus(hash2)),
            uint8(IIntentSource.Status.Initial),
            "intent2 is unsettled -- publish will not reject a repeat"
        );
        assertEq(tokenB.balanceOf(vault2), SWAP_OUT, "vault funded once");

        // A second intent1 -- different salt, same committed order, same swap output -- collides.
        IntentChainer.Order memory order = _order(SPREAD, 0);
        uint256 solverBefore = _prepareSolver(solver2, SWAP_IN);

        vm.prank(solver2);
        vm.expectRevert();
        portal.fulfill(
            _intentOneHash(bytes32(uint256(11)), order),
            _intentOneRoute(bytes32(uint256(11)), order),
            keccak256(abi.encode(_intentOneReward())),
            bytes32(uint256(uint160(claimant)))
        );

        assertEq(
            tokenB.balanceOf(vault2),
            SWAP_OUT,
            "vault was not topped up a second time"
        );
        assertEq(
            tokenA.balanceOf(solver2),
            solverBefore,
            "second solver keeps their input"
        );
        assertEq(
            tokenB.balanceOf(address(chainer)),
            0,
            "nothing left in the chainer"
        );
    }

    /**
     * @notice A template whose intent2 hash has already settled reverts rather than losing the push.
     * @dev The terminal half of the same failure mode: here `publish` itself rejects, because `Withdrawn` is
     *      one of the two states `_validatePublish` refuses. Kept alongside the unsettled case above so both
     *      halves stay pinned.
     */
    function test_atomicity_settledIntentTwoHashRevertsBeforeAnyPush() public {
        (bytes32 hash2, ) = _runChain(bytes32(uint256(6)), SPREAD);

        _addProof(hash2, uint96(DEST_CHAIN), claimant);
        portal.withdraw(
            DEST_CHAIN,
            keccak256(_routeBytes(SWAP_NET)),
            _intentTwoReward(SWAP_OUT)
        );
        assertEq(
            uint8(portal.getRewardStatus(hash2)),
            uint8(IIntentSource.Status.Withdrawn),
            "intent2 is settled"
        );

        // A second intent1 -- different salt, same committed order -- collides on intent2's hash.
        IntentChainer.Order memory order = _order(SPREAD, 0);
        uint256 solverBefore = _prepareSolver(solver2, SWAP_IN);

        vm.prank(solver2);
        vm.expectRevert();
        portal.fulfill(
            _intentOneHash(bytes32(uint256(7)), order),
            _intentOneRoute(bytes32(uint256(7)), order),
            keccak256(abi.encode(_intentOneReward())),
            bytes32(uint256(uint160(claimant)))
        );

        assertEq(
            tokenA.balanceOf(solver2),
            solverBefore,
            "second solver keeps their input"
        );
        assertEq(
            tokenB.balanceOf(address(chainer)),
            0,
            "nothing was pushed on the failed attempt"
        );
    }

    /**
     * @notice Neither the chainer nor the shared Executor retains a balance after a clean run.
     */
    function test_atomicity_noResidueInChainerOrExecutor() public {
        _runChain(bytes32(uint256(8)), SPREAD);

        assertEq(
            tokenB.balanceOf(address(chainer)),
            0,
            "chainer holds no residue"
        );
        assertEq(
            tokenA.balanceOf(address(portal.executor())),
            0,
            "executor holds no route-token residue"
        );
        assertEq(
            tokenB.balanceOf(address(portal.executor())),
            0,
            "executor holds no swap-output residue"
        );
    }

    // ============ Drivers ============

    /// @notice Fulfil an intent1 that swaps into the chainer and invokes it. Returns intent2's identity.
    function _runChain(
        bytes32 saltOne,
        uint256 scale
    ) internal returns (bytes32 hash2, address vault2) {
        IntentChainer.Order memory order = _order(scale, 0);

        _prepareSolver(solver, SWAP_IN);
        vm.prank(solver);
        portal.fulfill(
            _intentOneHash(saltOne, order),
            _intentOneRoute(saltOne, order),
            keccak256(abi.encode(_intentOneReward())),
            bytes32(uint256(uint160(claimant)))
        );

        bytes memory routeBytes = _routeBytes(SWAP_NET);
        hash2 = keccak256(
            abi.encodePacked(
                DEST_CHAIN,
                keccak256(routeBytes),
                keccak256(abi.encode(_intentTwoReward(SWAP_OUT)))
            )
        );
        vault2 = portal.intentVaultAddress(
            DEST_CHAIN,
            routeBytes,
            _intentTwoReward(SWAP_OUT)
        );
    }

    function _prepareSolver(
        address who,
        uint256 amount
    ) internal returns (uint256 balanceAfterMint) {
        tokenA.mint(who, amount);
        vm.prank(who);
        tokenA.approve(address(portal), amount);

        return tokenA.balanceOf(who);
    }

    // ============ Intent2 fixtures ============

    function _intentTwoReward(
        uint256 amountIn
    ) internal view returns (Reward memory) {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(tokenB), amount: amountIn});

        return
            Reward({
                deadline: intentTwoDeadline,
                creator: creator,
                prover: address(prover),
                nativeAmount: 0,
                tokens: tokens
            });
    }

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
                salt: bytes32(uint256(0xBEEF)),
                deadline: intentTwoDeadline,
                portal: address(portal),
                nativeAmount: 0,
                tokens: tokens,
                calls: routeCalls
            });
    }

    function _routeBytes(
        uint256 amountOut
    ) internal view returns (bytes memory) {
        return abi.encode(_intentTwoRoute(amountOut));
    }

    /// @notice Build the order the way an SDK does: encode with a sentinel, split on it.
    function _order(
        uint256 scale,
        uint256 minAmountIn
    ) internal view returns (IntentChainer.Order memory) {
        bytes[] memory segments = _splitOnMarker(
            abi.encode(_intentTwoRoute(uint256(MARKER)))
        );

        IntentChainer.Slot[] memory slots = new IntentChainer.Slot[](
            segments.length - 1
        );
        for (uint256 i = 0; i < slots.length; ++i) {
            slots[i] = IntentChainer.Slot({width: 32, littleEndian: false});
        }

        return
            IntentChainer.Order({
                portal: address(portal),
                token: address(tokenB),
                destination: DEST_CHAIN,
                segments: segments,
                slots: slots,
                reward: _intentTwoReward(0),
                scale: scale,
                minAmountIn: minAmountIn
            });
    }

    // ============ Intent1 fixtures ============

    function _intentOneRoute(
        bytes32 saltOne,
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
                IntegrationSwapper.swap,
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
                salt: saltOne,
                deadline: intentOneDeadline,
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
                deadline: intentOneDeadline,
                creator: creator,
                prover: address(prover),
                nativeAmount: 0,
                tokens: tokens
            });
    }

    function _intentOneHash(
        bytes32 saltOne,
        IntentChainer.Order memory order
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    uint64(block.chainid),
                    keccak256(abi.encode(_intentOneRoute(saltOne, order))),
                    keccak256(abi.encode(_intentOneReward()))
                )
            );
    }

    // ============ Sentinel splitting ============

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
}
