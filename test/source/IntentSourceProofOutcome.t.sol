// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {Intent} from "../../contracts/types/Intent.sol";

/// @dev Returns whatever ProofData it is given, including shapes no real prover records
contract ArbitraryProofProver {
    IProver.ProofData internal proof;
    bool public challenged;

    function setProof(IProver.ProofData memory _proof) external {
        proof = _proof;
    }

    function provenIntents(
        bytes32
    ) external view returns (IProver.ProofData memory) {
        return proof;
    }

    function challengeIntentProof(uint64, bytes32, bytes32) external {
        challenged = true;
        delete proof;
    }
}

/**
 * @notice Pins refund and withdraw against every (outcome, claimant, destination,
 * deadline) combination a prover can return, using a reference model of the
 * settlement rules
 */
contract IntentSourceProofOutcomeTest is BaseTest {
    ArbitraryProofProver internal anyProver;

    function setUp() public override {
        super.setUp();
        anyProver = new ArbitraryProofProver();
        _mintAndApprove(creator, MINT_AMOUNT);
    }

    function _setup(
        uint8 outcomeSeed,
        bool zeroClaimant,
        bool matchingDestination,
        bool pastDeadline
    )
        internal
        returns (
            Intent memory i,
            bytes32 intentHash,
            IProver.ProofData memory proof
        )
    {
        i = intent;
        i.reward.prover = address(anyProver);
        _publishAndFund(i, false);
        intentHash = _hashIntent(i);

        proof = IProver.ProofData({
            claimant: zeroClaimant ? address(0) : claimant,
            destination: matchingDestination
                ? i.destination
                : i.destination + 1,
            outcome: IProver.Outcome(outcomeSeed % 3)
        });
        anyProver.setProof(proof);

        if (pastDeadline) vm.warp(i.reward.deadline);
    }

    function testFuzzRefundMatchesSettlementRules(
        uint8 outcomeSeed,
        bool zeroClaimant,
        bool matchingDestination,
        bool pastDeadline
    ) public {
        (
            Intent memory i,
            bytes32 intentHash,
            IProver.ProofData memory proof
        ) = _setup(
                outcomeSeed,
                zeroClaimant,
                matchingDestination,
                pastDeadline
            );
        bool onDestination = proof.destination == i.destination;
        bool fulfilled = proof.outcome == IProver.Outcome.Fulfilled &&
            proof.claimant != address(0);

        if (onDestination && proof.outcome == IProver.Outcome.Cancelled) {
            // refunds immediately
        } else if (onDestination && fulfilled) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IIntentSource.IntentNotClaimed.selector,
                    intentHash
                )
            );
        } else if (!pastDeadline) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IIntentSource.InvalidStatusForRefund.selector,
                    IIntentSource.Status.Funded,
                    block.timestamp,
                    i.reward.deadline
                )
            );
        }

        intentSource.refund(
            i.destination,
            keccak256(abi.encode(i.route)),
            i.reward
        );
    }

    function testFuzzWithdrawMatchesSettlementRules(
        uint8 outcomeSeed,
        bool zeroClaimant,
        bool matchingDestination,
        bool pastDeadline
    ) public {
        (
            Intent memory i,
            bytes32 intentHash,
            IProver.ProofData memory proof
        ) = _setup(
                outcomeSeed,
                zeroClaimant,
                matchingDestination,
                pastDeadline
            );
        bool wrongDestination = proof.outcome != IProver.Outcome.None &&
            proof.destination != i.destination;

        if (wrongDestination) {
            // challenged instead of settled
        } else if (proof.outcome == IProver.Outcome.Cancelled) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IIntentSource.CancelledIntent.selector,
                    intentHash
                )
            );
        } else if (
            proof.outcome != IProver.Outcome.Fulfilled ||
            proof.claimant == address(0)
        ) {
            vm.expectRevert(IIntentSource.InvalidClaimant.selector);
        }

        intentSource.withdraw(
            i.destination,
            keccak256(abi.encode(i.route)),
            i.reward
        );

        assertEq(anyProver.challenged(), wrongDestination);
        bool withdrawn = !wrongDestination &&
            proof.outcome == IProver.Outcome.Fulfilled &&
            proof.claimant != address(0);
        assertEq(
            uint256(intentSource.getRewardStatus(intentHash)),
            uint256(
                withdrawn
                    ? IIntentSource.Status.Withdrawn
                    : IIntentSource.Status.Funded
            )
        );
    }
}
