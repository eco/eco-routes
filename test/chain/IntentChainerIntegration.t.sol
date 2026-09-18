/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {BaseTest} from "../BaseTest.sol";
import {IntentChainer} from "../../contracts/chain/IntentChainer.sol";
import {IntentTemplate} from "../../contracts/chain/IntentTemplate.sol";
import {TemplateFixtures} from "./TemplateFixtures.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {IInbox} from "../../contracts/interfaces/IInbox.sol";
import {IExecutor} from "../../contracts/interfaces/IExecutor.sol";
import {FeeOnPushToken} from "../../contracts/test/FeeOnPushToken.sol";
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
 * @dev Tests drive real `portal.fulfill` calls and check funding, rollback, withdrawal or refund.
 *      Nothing calls `chain()` directly.
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
     * @notice Different parents may fund the same unsettled child; child-salt uniqueness is caller-owned.
     */
    function test_funding_distinctParentsMayReuseUnsettledChild() public {
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

        // Deliberately reuse the child template, but not the parent identity.
        IntentChainer.Order memory order = _order(SPREAD, 0);
        uint256 solverBefore = _prepareSolver(solver2, SWAP_IN);
        bytes32 parent2 = _intentOneHash(bytes32(uint256(11)), order);
        assertNotEq(parent2, _intentOneHash(bytes32(uint256(10)), order));

        vm.prank(solver2);
        portal.fulfill(
            parent2,
            _intentOneRoute(bytes32(uint256(11)), order),
            keccak256(abi.encode(_intentOneReward())),
            bytes32(uint256(uint160(claimant)))
        );

        assertEq(
            tokenB.balanceOf(vault2),
            2 * SWAP_OUT,
            "both measured pushes reach the same vault"
        );
        assertEq(
            tokenA.balanceOf(solver2),
            solverBefore - SWAP_IN,
            "second parent executes independently"
        );
        assertEq(
            tokenB.balanceOf(address(chainer)),
            0,
            "nothing left in the chainer"
        );
        assertEq(
            portal.claimants(parent2),
            bytes32(uint256(uint160(claimant)))
        );

        _addProof(hash2, uint96(DEST_CHAIN), claimant);
        uint256 claimantBefore = tokenB.balanceOf(claimant);
        portal.withdraw(
            DEST_CHAIN,
            keccak256(_routeBytes(SWAP_NET)),
            _intentTwoReward(SWAP_OUT)
        );
        assertEq(
            tokenB.balanceOf(claimant) - claimantBefore,
            SWAP_OUT,
            "reward is not doubled"
        );
        assertEq(tokenB.balanceOf(vault2), SWAP_OUT, "second push is surplus");
        uint256 creatorBefore = tokenB.balanceOf(creator);
        portal.refund(
            DEST_CHAIN,
            keccak256(_routeBytes(SWAP_NET)),
            _intentTwoReward(SWAP_OUT)
        );
        assertEq(tokenB.balanceOf(creator) - creatorBefore, SWAP_OUT);
    }

    function test_atomicity_sameParentCannotBeFulfilledTwice() public {
        bytes32 parentSalt = bytes32(uint256(12));
        (, address vault2) = _runChain(parentSalt, SPREAD);
        IntentChainer.Order memory order = _order(SPREAD, 0);
        bytes32 parent = _intentOneHash(parentSalt, order);
        uint256 solverBefore = _prepareSolver(solver2, SWAP_IN);

        vm.prank(solver2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.IntentAlreadyFulfilled.selector,
                parent
            )
        );
        portal.fulfill(
            parent,
            _intentOneRoute(parentSalt, order),
            keccak256(abi.encode(_intentOneReward())),
            bytes32(uint256(uint160(claimant)))
        );

        assertEq(tokenA.balanceOf(solver2), solverBefore);
        assertEq(tokenB.balanceOf(vault2), SWAP_OUT);
    }

    function test_funding_prefundedVaultBelowPush() public {
        _assertPrefundedVault(1, true);
    }

    function test_funding_prefundedVaultEqualToPush() public {
        _assertPrefundedVault(SWAP_OUT, true);
    }

    function test_funding_prefundedVaultAbovePush() public {
        _assertPrefundedVault(SWAP_OUT * 2, true);
    }

    function test_funding_prefundedVaultWithoutPublication() public {
        _assertPrefundedVault(SWAP_OUT * 2, false);
    }

    function _assertPrefundedVault(uint256 prefunding, bool publish) internal {
        IntentChainer.Order memory order = _order(SPREAD, SWAP_OUT);
        order.publish = publish;
        address vault2 = portal.intentVaultAddress(
            DEST_CHAIN,
            _routeBytes(SWAP_NET),
            _intentTwoReward(SWAP_OUT)
        );
        uint256 before = tokenB.balanceOf(vault2);
        tokenB.mint(vault2, prefunding);
        bytes32 parentSalt = keccak256(abi.encode(prefunding, publish));
        _prepareSolver(solver, SWAP_IN);
        vm.prank(solver);
        portal.fulfill(
            _intentOneHash(parentSalt, order),
            _intentOneRoute(parentSalt, order),
            keccak256(abi.encode(_intentOneReward())),
            bytes32(uint256(uint160(claimant)))
        );
        assertEq(tokenB.balanceOf(vault2), before + prefunding + SWAP_OUT);
        assertEq(tokenB.balanceOf(address(chainer)), 0);
    }

    function test_atomicity_outboundFeeRollsBackFulfillment() public {
        _assertOutboundFeeRollback(0, true, false);
    }

    function test_atomicity_prefundingCannotMaskOutboundFee() public {
        _assertOutboundFeeRollback(SWAP_OUT * 2, true, false);
    }

    function test_atomicity_outboundFeeRollsBackWithoutPublication() public {
        _assertOutboundFeeRollback(SWAP_OUT * 2, false, false);
    }

    function test_atomicity_outboundFeeRestoresPreexistingChainerBalance()
        public
    {
        _assertOutboundFeeRollback(SWAP_OUT * 2, true, true);
    }

    /// @dev The Executor wraps PushShortfall in CallFailed: assert both layers exactly.
    ///      Receipt-level log rollback is covered by IntentChainer.spec.ts; recordLogs records
    ///      execution traces, including reverted logs, rather than a mined transaction receipt.
    function _assertOutboundFeeRollback(
        uint256 prefunding,
        bool publish,
        bool preseedChainer
    ) internal {
        FeeOnPushToken feeToken = new FeeOnPushToken(address(chainer));
        IntentChainer.Order memory order = _order(SPREAD, SWAP_OUT);
        order.token = address(feeToken);
        order.reward.tokens[0].token = address(feeToken);
        order.publish = publish;
        Reward memory childReward = _intentTwoReward(SWAP_OUT);
        childReward.tokens[0].token = address(feeToken);
        bytes memory childRoute = _routeBytes(SWAP_NET);
        address vault2 = portal.intentVaultAddress(
            DEST_CHAIN,
            childRoute,
            childReward
        );
        (bytes32 childHash, , ) = portal.getIntentHash(
            DEST_CHAIN,
            childRoute,
            childReward
        );
        feeToken.mint(vault2, prefunding);
        feeToken.mint(
            preseedChainer ? address(chainer) : address(swapper),
            SWAP_OUT
        );
        uint256 chainerBefore = feeToken.balanceOf(address(chainer));
        uint256 swapperBefore = feeToken.balanceOf(address(swapper));
        uint256 supplyBefore = feeToken.totalSupply();
        uint256 solverBefore = _prepareSolver(solver, SWAP_IN);
        uint256 inputBefore = tokenA.balanceOf(address(swapper));
        Route memory parentRoute = _intentOneRoute(bytes32(uint256(30)), order);
        parentRoute.calls[1].data = abi.encodeCall(
            IntegrationSwapper.swap,
            (address(feeToken), preseedChainer ? 0 : SWAP_OUT, address(chainer))
        );
        bytes32 rewardHash = keccak256(abi.encode(_intentOneReward()));
        bytes32 parent = keccak256(
            abi.encodePacked(
                uint64(block.chainid),
                keccak256(abi.encode(parentRoute)),
                rewardHash
            )
        );
        bytes memory shortfall = abi.encodeWithSelector(
            IntentChainer.PushShortfall.selector,
            vault2,
            SWAP_OUT,
            SWAP_OUT - 1
        );

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(
                IExecutor.CallFailed.selector,
                parentRoute.calls[2],
                shortfall
            )
        );
        portal.fulfill(
            parent,
            parentRoute,
            rewardHash,
            bytes32(uint256(uint160(claimant)))
        );

        assertEq(
            feeToken.balanceOf(address(chainer)),
            chainerBefore,
            "chainer restored"
        );
        assertEq(feeToken.balanceOf(vault2), prefunding, "vault unchanged");
        assertEq(
            feeToken.balanceOf(address(swapper)),
            swapperBefore,
            "swap undone"
        );
        assertEq(feeToken.totalSupply(), supplyBefore, "fee burn undone");
        assertEq(tokenA.balanceOf(solver), solverBefore, "solver refunded");
        assertEq(
            tokenA.balanceOf(address(swapper)),
            inputBefore,
            "input transfer undone"
        );
        assertEq(
            tokenA.balanceOf(address(portal.executor())),
            0,
            "no executor residue"
        );
        assertEq(portal.claimants(parent), bytes32(0), "parent not fulfilled");
        assertEq(
            uint8(portal.getRewardStatus(childHash)),
            uint8(IIntentSource.Status.Initial)
        );
    }

    /**
     * @notice A template whose intent2 hash has already settled reverts rather than losing the push.
     * @dev Unlike prefunding an unsettled child, pushing after settlement is rejected unconditionally.
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

    /**
     * @notice With publish off, intent2 is still funded and still withdrawable by its proven claimant.
     * @dev The point of the flag: publish buys discoverability and nothing else. The vault address comes
     *      from `intentVaultAddress`, and the settled check reads `getRewardStatus` -- neither depends on
     *      publishing -- so the escrow behaves identically. What a solver loses is `IntentPublished`.
     */
    function test_publishFlag_offStillFundsAWithdrawableIntent() public {
        IntentChainer.Order memory order = _order(SPREAD, 0);
        order.publish = false;

        _prepareSolver(solver, SWAP_IN);
        vm.recordLogs();
        vm.prank(solver);
        portal.fulfill(
            _intentOneHash(bytes32(uint256(20)), order),
            _intentOneRoute(bytes32(uint256(20)), order),
            keccak256(abi.encode(_intentOneReward())),
            bytes32(uint256(uint160(claimant)))
        );

        // No IntentPublished anywhere in the transaction.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IIntentSource.IntentPublished.selector,
                "publish:false must not emit IntentPublished"
            );
        }

        bytes memory routeBytes = _routeBytes(SWAP_NET);
        bytes32 hash2 = keccak256(
            abi.encodePacked(
                DEST_CHAIN,
                keccak256(routeBytes),
                keccak256(abi.encode(_intentTwoReward(SWAP_OUT)))
            )
        );
        address vault2 = portal.intentVaultAddress(
            DEST_CHAIN,
            routeBytes,
            _intentTwoReward(SWAP_OUT)
        );

        assertEq(tokenB.balanceOf(vault2), SWAP_OUT, "vault funded anyway");

        _addProof(hash2, uint96(DEST_CHAIN), claimant);
        uint256 before = tokenB.balanceOf(claimant);
        portal.withdraw(
            DEST_CHAIN,
            keccak256(routeBytes),
            _intentTwoReward(SWAP_OUT)
        );

        assertEq(
            tokenB.balanceOf(claimant) - before,
            SWAP_OUT,
            "claimant is paid without any publish having happened"
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

        IntentTemplate.Item[] memory slots = new IntentTemplate.Item[](
            segments.length - 1
        );
        for (uint256 i = 0; i < slots.length; ++i) {
            slots[i] = TemplateFixtures.amount(32, false);
        }

        return
            IntentChainer.Order({
                publish: true,
                portal: address(portal),
                token: address(tokenB),
                destination: DEST_CHAIN,
                template: TemplateFixtures.program(segments, slots),
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
