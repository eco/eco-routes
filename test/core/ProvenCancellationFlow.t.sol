// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {IInbox} from "../../contracts/interfaces/IInbox.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {Intent, CANCELLED_CLAIMANT} from "../../contracts/types/Intent.sol";

/// @dev Reader compiled against the pre-cancellation two-word ProofData
interface ILegacyProofReader {
    struct LegacyProofData {
        address claimant;
        uint64 destination;
    }

    function provenIntents(
        bytes32 intentHash
    ) external view returns (LegacyProofData memory);
}

/// @notice Cancel on the destination, prove to the source, refund before reward.deadline
contract ProvenCancellationFlowTest is BaseTest {
    address internal solver;

    function setUp() public override {
        super.setUp();
        solver = makeAddr("solver");
        _mintAndApprove(creator, MINT_AMOUNT);
        _mintAndApprove(solver, MINT_AMOUNT);
    }

    // Same Portal is source and destination; product-shaped deadlines
    function _sameChainIntent()
        internal
        view
        returns (
            Intent memory i,
            bytes32 routeHash,
            bytes32 rewardHash,
            bytes32 intentHash
        )
    {
        i = intent;
        i.destination = uint64(block.chainid);
        i.route.deadline = uint64(block.timestamp + 5 minutes);
        i.reward.deadline = uint64(block.timestamp + 7 days);
        routeHash = keccak256(abi.encode(i.route));
        rewardHash = keccak256(abi.encode(i.reward));
        intentHash = keccak256(
            abi.encodePacked(i.destination, routeHash, rewardHash)
        );
    }

    function testCancelProveAndRefundBeforeRewardDeadline() public {
        (
            Intent memory i,
            bytes32 routeHash,
            bytes32 rewardHash,
            bytes32 intentHash
        ) = _sameChainIntent();
        _publishAndFund(i, false);

        vm.warp(uint256(i.route.deadline) + 1);
        vm.prank(otherPerson);
        portal.cancelAndProve(
            intentHash,
            i.route,
            rewardHash,
            address(prover),
            uint64(block.chainid),
            ""
        );

        IProver.ProofData memory proof = prover.provenIntents(intentHash);
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Cancelled));
        assertEq(proof.destination, uint64(block.chainid));

        assertLt(block.timestamp, i.reward.deadline);
        vm.prank(otherPerson);
        intentSource.refund(i.destination, routeHash, i.reward);
        assertEq(tokenA.balanceOf(creator), MINT_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidStatusForWithdrawal.selector,
                IIntentSource.Status.Refunded
            )
        );
        intentSource.withdraw(i.destination, routeHash, i.reward);
    }

    function testFulfilledIntentCannotBeCancelledOrRefundedEarly() public {
        (
            Intent memory i,
            bytes32 routeHash,
            bytes32 rewardHash,
            bytes32 intentHash
        ) = _sameChainIntent();
        _publishAndFund(i, false);

        vm.warp(i.route.deadline);
        vm.prank(solver);
        portal.fulfillAndProve(
            intentHash,
            i.route,
            rewardHash,
            bytes32(uint256(uint160(claimant))),
            address(prover),
            uint64(block.chainid),
            ""
        );

        vm.warp(uint256(i.route.deadline) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.IntentAlreadyFulfilled.selector,
                intentHash
            )
        );
        portal.cancel(intentHash, i.route, rewardHash);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.IntentNotClaimed.selector,
                intentHash
            )
        );
        intentSource.refund(i.destination, routeHash, i.reward);

        intentSource.withdraw(i.destination, routeHash, i.reward);
        assertEq(tokenA.balanceOf(claimant), MINT_AMOUNT);
    }

    // Spec invariant 6: a reader unaware of cancellation sees "unproven".
    // Seeded through the real prove()/_recordProof() path (not the
    // addCancelledIntent test helper) so the assertion pins what that path
    // actually writes, not just ABI extra-word tolerance.
    function testLegacyTwoWordReaderSeesCancelledProofAsUnproven() public {
        bytes32 intentHash = keccak256("cancelled");
        prover.prove(
            address(this),
            CHAIN_ID,
            abi.encodePacked(CHAIN_ID, intentHash, CANCELLED_CLAIMANT),
            ""
        );

        ILegacyProofReader.LegacyProofData memory legacy = ILegacyProofReader(
            address(prover)
        ).provenIntents(intentHash);

        assertEq(legacy.claimant, address(0));
        assertEq(legacy.destination, CHAIN_ID);
    }
}
