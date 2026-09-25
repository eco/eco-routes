// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";

contract IntentSourceCancellationTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _mintAndApprove(creator, MINT_AMOUNT);
    }

    function _routeHash() internal view returns (bytes32) {
        return keccak256(abi.encode(intent.route));
    }

    function testRefundBeforeRewardDeadlineWithProvenCancellation() public {
        _publishAndFund(intent, false);
        bytes32 intentHash = _hashIntent(intent);
        prover.addCancelledIntent(intentHash, CHAIN_ID);
        uint256 creatorA = tokenA.balanceOf(creator);
        uint256 creatorB = tokenB.balanceOf(creator);
        assertLt(block.timestamp, intent.reward.deadline);

        vm.expectEmit(true, true, true, true, address(portal));
        emit IIntentSource.IntentRefunded(intentHash, creator);
        vm.prank(otherPerson);
        intentSource.refund(intent.destination, _routeHash(), intent.reward);

        assertEq(tokenA.balanceOf(creator), creatorA + MINT_AMOUNT);
        assertEq(tokenB.balanceOf(creator), creatorB + MINT_AMOUNT * 2);
        assertEq(
            uint256(intentSource.getRewardStatus(intentHash)),
            uint256(IIntentSource.Status.Refunded)
        );
    }

    function testRefundToBeforeRewardDeadlineWithProvenCancellation() public {
        _publishAndFund(intent, false);
        bytes32 intentHash = _hashIntent(intent);
        prover.addCancelledIntent(intentHash, CHAIN_ID);
        address refundee = makeAddr("refundee");

        vm.prank(creator);
        intentSource.refundTo(
            intent.destination,
            _routeHash(),
            intent.reward,
            refundee
        );

        assertEq(tokenA.balanceOf(refundee), MINT_AMOUNT);
    }

    function testCancellationOnWrongDestinationFallsBackToDeadline() public {
        _publishAndFund(intent, false);
        bytes32 intentHash = _hashIntent(intent);
        prover.addCancelledIntent(intentHash, CHAIN_ID + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidStatusForRefund.selector,
                IIntentSource.Status.Funded,
                block.timestamp,
                intent.reward.deadline
            )
        );
        intentSource.refund(intent.destination, _routeHash(), intent.reward);

        vm.warp(intent.reward.deadline);
        intentSource.refund(intent.destination, _routeHash(), intent.reward);
        assertEq(tokenA.balanceOf(creator), MINT_AMOUNT);
    }

    function testWithdrawRevertsOnProvenCancellation() public {
        _publishAndFund(intent, false);
        bytes32 intentHash = _hashIntent(intent);
        prover.addCancelledIntent(intentHash, CHAIN_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.CancelledIntent.selector,
                intentHash
            )
        );
        intentSource.withdraw(intent.destination, _routeHash(), intent.reward);
    }

    function testWithdrawChallengesWrongDestinationCancellation() public {
        _publishAndFund(intent, false);
        bytes32 intentHash = _hashIntent(intent);
        prover.addCancelledIntent(intentHash, CHAIN_ID + 1);

        vm.expectEmit(true, true, true, true, address(prover));
        emit IProver.IntentProofInvalidated(intentHash);
        intentSource.withdraw(intent.destination, _routeHash(), intent.reward);

        assertEq(
            uint8(prover.provenIntents(intentHash).outcome),
            uint8(IProver.Outcome.None)
        );
        assertTrue(intentSource.isIntentFunded(intent));
    }

    function testFulfilledProofStillBlocksEarlyRefund() public {
        _publishAndFund(intent, false);
        bytes32 intentHash = _hashIntent(intent);
        prover.addProvenIntent(intentHash, claimant, CHAIN_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.IntentNotClaimed.selector,
                intentHash
            )
        );
        intentSource.refund(intent.destination, _routeHash(), intent.reward);
    }

    function testNoProofStillRequiresRewardDeadline() public {
        _publishAndFund(intent, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidStatusForRefund.selector,
                IIntentSource.Status.Funded,
                block.timestamp,
                intent.reward.deadline
            )
        );
        intentSource.refund(intent.destination, _routeHash(), intent.reward);
    }

    function testRefundedCancellationCannotBeWithdrawn() public {
        _publishAndFund(intent, false);
        bytes32 intentHash = _hashIntent(intent);
        prover.addCancelledIntent(intentHash, CHAIN_ID);
        intentSource.refund(intent.destination, _routeHash(), intent.reward);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidStatusForWithdrawal.selector,
                IIntentSource.Status.Refunded
            )
        );
        intentSource.withdraw(intent.destination, _routeHash(), intent.reward);
    }
}
