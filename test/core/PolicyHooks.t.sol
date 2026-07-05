// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../BaseTest.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {IAccount} from "../../contracts/interfaces/IAccount.sol";
import {Hook} from "../../contracts/types/Intent.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HookBeacon, HookLogic} from "./HookHelpers.sol";

/**
 * @title PolicyHooksTest
 * @notice Tests for keeper-committed `reward.hooks` delegate hooks (PR5): the default `Hook[2]`
 *         encoding, invocation on settle (reward hook) / refund (refund hook), the empty-hooks default,
 *         and the money-safety failure semantics (best-effort, CEI, reentrancy containment, isolation).
 */
contract PolicyHooksTest is BaseTest {
    HookBeacon internal beacon;
    HookLogic internal hookLogic;

    function setUp() public override {
        super.setUp();
        _mintAndApprove(keeper, MINT_AMOUNT);
        _fundUserNative(keeper, 10 ether);
        beacon = new HookBeacon();
        hookLogic = new HookLogic();
    }

    // --- helpers -------------------------------------------------------------------------------------

    /// @notice Encode the default `Reward.hooks` = `abi.encode(Hook[2])` (index 0 reward, index 1 refund).
    function _hooks(
        address rTarget,
        bytes memory rData,
        address fTarget,
        bytes memory fData
    ) internal pure returns (bytes memory) {
        Hook[2] memory h;
        h[0] = Hook({target: rTarget, data: rData});
        h[1] = Hook({target: fTarget, data: fData});
        return abi.encode(h);
    }

    function _rewardHookOnly(
        address target,
        bytes memory data
    ) internal pure returns (bytes memory) {
        return _hooks(target, data, address(0), "");
    }

    function _refundHookOnly(
        address target,
        bytes memory data
    ) internal pure returns (bytes memory) {
        return _hooks(address(0), "", target, data);
    }

    function _fundProveIntent() internal returns (bytes32 intentHash) {
        _publishAndFund(intent, false);
        intentHash = _hashIntent(intent);
        _addProof(intentHash, CHAIN_ID, claimant);
    }

    function _settleDefault() internal {
        vm.prank(otherPerson);
        intentSource.settle(
            intent.protocolVersion,
            intent.source,
            intent.destination,
            keccak256(abi.encode(intent.route)),
            intent.reward,
            bytes32(uint256(uint160(claimant))),
            _defaultFulfilled()
        );
    }

    function _refundDefault() internal {
        intentSource.refund(
            intent.protocolVersion,
            intent.source,
            intent.destination,
            keccak256(abi.encode(intent.route)),
            intent.reward
        );
    }

    // --- reward hook on settle ----------------------------------------------------------------------

    function test_hooks_rewardHookRunsOnSettle_asTheAccount() public {
        intent.reward.hooks = _rewardHookOnly(
            address(hookLogic),
            abi.encodeCall(HookLogic.reward, (address(beacon)))
        );
        address sourceAccount = intentSource.intentAccountAddress(intent);

        _fundProveIntent();

        uint256 balA = tokenA.balanceOf(claimant);
        uint256 balB = tokenB.balanceOf(claimant);
        _settleDefault();

        // Reward hook ran exactly once, as the intent's own (source/escrow) account.
        assertEq(beacon.rewardPings(), 1, "reward hook should run once");
        assertEq(beacon.refundPings(), 0, "refund hook must not run on settle");
        assertEq(beacon.lastCaller(), sourceAccount, "hook must run AS the account");

        // Core settle effects are intact (solver paid the full reward).
        assertEq(tokenA.balanceOf(claimant), balA + MINT_AMOUNT);
        assertEq(tokenB.balanceOf(claimant), balB + MINT_AMOUNT * 2);
        assertEq(
            uint256(intentSource.getRewardStatus(_hashIntent(intent))),
            uint256(IIntentSource.Status.Withdrawn)
        );
    }

    function test_hooks_rewardHookTargetZeroIsSkipped() public {
        // Reward slot present but target == address(0) => skipped no-op.
        intent.reward.hooks = _hooks(
            address(0),
            "",
            address(hookLogic),
            abi.encodeCall(HookLogic.refund, (address(beacon)))
        );
        _fundProveIntent();
        _settleDefault();
        assertEq(beacon.rewardPings(), 0, "zero-target reward hook is a no-op");
    }

    // --- refund hook on refund ----------------------------------------------------------------------

    function test_hooks_refundHookRunsOnRefund_asTheAccount() public {
        intent.reward.hooks = _refundHookOnly(
            address(hookLogic),
            abi.encodeCall(HookLogic.refund, (address(beacon)))
        );
        address sourceAccount = intentSource.intentAccountAddress(intent);

        _publishAndFund(intent, false);
        // Move past the reward deadline so refund is allowed.
        _timeTravel(intent.reward.deadline + 1);

        uint256 balA = tokenA.balanceOf(keeper);
        _refundDefault();

        assertEq(beacon.refundPings(), 1, "refund hook should run once");
        assertEq(beacon.rewardPings(), 0, "reward hook must not run on refund");
        assertEq(beacon.lastCaller(), sourceAccount, "hook must run AS the account");

        // Escrow returned to the keeper.
        assertEq(tokenA.balanceOf(keeper), balA + MINT_AMOUNT);
        assertEq(
            uint256(intentSource.getRewardStatus(_hashIntent(intent))),
            uint256(IIntentSource.Status.Refunded)
        );
    }

    // --- empty hooks (the common case) --------------------------------------------------------------

    function test_hooks_emptyHooksSettleUnaffected() public {
        // Default intent carries empty hooks.
        assertEq(intent.reward.hooks.length, 0);
        _fundProveIntent();

        uint256 balA = tokenA.balanceOf(claimant);
        _settleDefault();

        assertEq(beacon.rewardPings(), 0);
        assertEq(tokenA.balanceOf(claimant), balA + MINT_AMOUNT);
    }

    function test_hooks_emptyHooksRefundUnaffected() public {
        _publishAndFund(intent, false);
        _timeTravel(intent.reward.deadline + 1);
        uint256 balA = tokenA.balanceOf(keeper);
        _refundDefault();
        assertEq(beacon.refundPings(), 0);
        assertEq(tokenA.balanceOf(keeper), balA + MINT_AMOUNT);
    }

    // --- failure semantics: best-effort, never strands money ----------------------------------------

    function test_hooks_revertingRewardHookStillPaysSolver() public {
        intent.reward.hooks = _rewardHookOnly(
            address(hookLogic),
            abi.encodeCall(HookLogic.boom, ())
        );
        bytes32 intentHash = _fundProveIntent();

        uint256 balA = tokenA.balanceOf(claimant);
        uint256 balB = tokenB.balanceOf(claimant);

        // Settle still succeeds and emits HookReverted for the reward slot (index 0).
        _expectEmit();
        emit IIntentSource.HookReverted(intentHash, 0);
        _settleDefault();

        // Solver was paid the full reward despite the reverting hook.
        assertEq(tokenA.balanceOf(claimant), balA + MINT_AMOUNT);
        assertEq(tokenB.balanceOf(claimant), balB + MINT_AMOUNT * 2);
        assertEq(
            uint256(intentSource.getRewardStatus(intentHash)),
            uint256(IIntentSource.Status.Withdrawn)
        );
    }

    function test_hooks_revertingRefundHookDoesNotLockRefund() public {
        intent.reward.hooks = _refundHookOnly(
            address(hookLogic),
            abi.encodeCall(HookLogic.boom, ())
        );
        _publishAndFund(intent, false);
        bytes32 intentHash = _hashIntent(intent);
        _timeTravel(intent.reward.deadline + 1);

        uint256 balA = tokenA.balanceOf(keeper);

        _expectEmit();
        emit IIntentSource.HookReverted(intentHash, 1);
        _refundDefault();

        // Keeper's refund completed despite the reverting refund hook.
        assertEq(tokenA.balanceOf(keeper), balA + MINT_AMOUNT);
        assertEq(
            uint256(intentSource.getRewardStatus(intentHash)),
            uint256(IIntentSource.Status.Refunded)
        );
    }

    function test_hooks_malformedHooksCaughtOnSettle() public {
        // Non-empty hooks that are NOT a valid abi.encode(Hook[2]) => decode reverts in the Account, caught.
        intent.reward.hooks = hex"deadbeef";
        bytes32 intentHash = _fundProveIntent();

        uint256 balA = tokenA.balanceOf(claimant);

        _expectEmit();
        emit IIntentSource.HookReverted(intentHash, 0);
        _settleDefault();

        assertEq(tokenA.balanceOf(claimant), balA + MINT_AMOUNT);
        assertEq(
            uint256(intentSource.getRewardStatus(intentHash)),
            uint256(IIntentSource.Status.Withdrawn)
        );
    }

    // --- reentrancy containment ---------------------------------------------------------------------

    function test_hooks_hookCannotReinvokeAccountExecute() public {
        // Reward hook tries to re-drive the Account's runHook (execute machinery) directly. It runs AS the
        // account, so msg.sender to runHook is the account, not the Portal => onlyPortal blocks it => the
        // hook reverts and is caught; the solver is still paid exactly once.
        bytes memory inner = _rewardHookOnly(
            address(hookLogic),
            abi.encodeCall(HookLogic.reward, (address(beacon)))
        );
        intent.reward.hooks = _rewardHookOnly(
            address(hookLogic),
            abi.encodeCall(HookLogic.reinvokeExecute, (inner))
        );
        bytes32 intentHash = _fundProveIntent();

        uint256 balA = tokenA.balanceOf(claimant);

        _expectEmit();
        emit IIntentSource.HookReverted(intentHash, 0);
        _settleDefault();

        assertEq(beacon.rewardPings(), 0, "inner re-invocation must be blocked");
        assertEq(tokenA.balanceOf(claimant), balA + MINT_AMOUNT);
    }

    function test_hooks_reentrantSettleOnTerminalStatusRevertsNoDoubleSpend()
        public
    {
        // Intent A: plain (empty hooks) — funded, proven, settled first so its status is terminal.
        Intent memory intentA = intent;
        intentA.route.salt = keccak256("A");
        // fresh escrow for A
        _mintAndApprove(keeper, MINT_AMOUNT);
        vm.prank(keeper);
        intentSource.publishAndFund(intentA, false);
        bytes32 hashA = _hashIntent(intentA);
        _addProof(hashA, CHAIN_ID, claimant);
        vm.prank(otherPerson);
        intentSource.settle(
            intentA.protocolVersion,
            intentA.source,
            intentA.destination,
            keccak256(abi.encode(intentA.route)),
            intentA.reward,
            bytes32(uint256(uint160(claimant))),
            _defaultFulfilled()
        );
        uint256 claimantAafter = tokenA.balanceOf(claimant);

        // Intent B: reward hook reenters settle(A). A is already Withdrawn => the reentrant settle reverts
        // (InvalidStatusForWithdrawal) => B's hook reverts => caught. A is NOT double-paid.
        bytes memory reenterCd = abi.encodeCall(
            IIntentSource.settle,
            (
                intentA.protocolVersion,
                intentA.source,
                intentA.destination,
                keccak256(abi.encode(intentA.route)),
                intentA.reward,
                bytes32(uint256(uint160(claimant))),
                _defaultFulfilled()
            )
        );
        Intent memory intentB = intent;
        intentB.route.salt = keccak256("B");
        intentB.reward.hooks = _rewardHookOnly(
            address(hookLogic),
            abi.encodeCall(HookLogic.reenter, (address(intentSource), reenterCd))
        );
        _mintAndApprove(keeper, MINT_AMOUNT);
        vm.prank(keeper);
        intentSource.publishAndFund(intentB, false);
        bytes32 hashB = _hashIntent(intentB);
        _addProof(hashB, CHAIN_ID, claimant);

        _expectEmit();
        emit IIntentSource.HookReverted(hashB, 0);
        vm.prank(otherPerson);
        intentSource.settle(
            intentB.protocolVersion,
            intentB.source,
            intentB.destination,
            keccak256(abi.encode(intentB.route)),
            intentB.reward,
            bytes32(uint256(uint160(claimant))),
            _defaultFulfilled()
        );

        // A was not double-paid by the reentrant settle; B paid once.
        assertEq(
            tokenA.balanceOf(claimant),
            claimantAafter + MINT_AMOUNT,
            "A must not be double-paid; B paid once"
        );
    }

    // --- per-intent isolation -----------------------------------------------------------------------

    function test_hooks_cannotTouchAnotherIntentsEscrow() public {
        // Intent Y: a LIVE, funded intent whose escrow must be untouchable by another intent's hook.
        Intent memory intentY = intent;
        intentY.route.salt = keccak256("Y");
        _mintAndApprove(keeper, MINT_AMOUNT);
        vm.prank(keeper);
        intentSource.publishAndFund(intentY, false);
        address accountY = intentSource.intentAccountAddress(intentY);
        uint256 accountYbalB = tokenB.balanceOf(accountY);
        assertGt(accountYbalB, 0);

        // Intent X: reward hook attempts to pull Y's tokenB escrow. It runs AS X's account, which has no
        // allowance over Y's account, so the transferFrom reverts => caught. Y's escrow is untouched.
        intent.route.salt = keccak256("X");
        intent.reward.hooks = _rewardHookOnly(
            address(hookLogic),
            abi.encodeCall(
                HookLogic.steal,
                (address(tokenB), accountY, otherPerson, accountYbalB)
            )
        );
        _mintAndApprove(keeper, MINT_AMOUNT);
        vm.prank(keeper);
        intentSource.publishAndFund(intent, false);
        bytes32 hashX = _hashIntent(intent);
        _addProof(hashX, CHAIN_ID, claimant);

        uint256 balA = tokenA.balanceOf(claimant);
        _expectEmit();
        emit IIntentSource.HookReverted(hashX, 0);
        _settleDefault();

        // Y's escrow intact; X's solver paid.
        assertEq(
            tokenB.balanceOf(accountY),
            accountYbalB,
            "Y escrow must be intact"
        );
        assertEq(tokenA.balanceOf(claimant), balA + MINT_AMOUNT);
    }

    // --- Account entrypoint gating ------------------------------------------------------------------

    function test_hooks_runHookIsOnlyPortal() public {
        _fundProveIntent();
        address sourceAccount = intentSource.intentAccountAddress(intent);
        // Settle first so the account is deployed.
        _settleDefault();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccount.NotPortalCaller.selector,
                address(this)
            )
        );
        IAccount(sourceAccount).runHook(
            _rewardHookOnly(
                address(hookLogic),
                abi.encodeCall(HookLogic.reward, (address(beacon)))
            ),
            0
        );
    }
}
