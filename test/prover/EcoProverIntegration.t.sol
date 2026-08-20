// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {EcoProver} from "../../contracts/prover/EcoProver.sol";
import {Portal} from "../../contracts/Portal.sol";
import {TestProver} from "../../contracts/test/TestProver.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../../contracts/types/Intent.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";

contract EcoProverIntegrationTest is Test {
    Portal internal portal;
    TestProver internal proverA;
    TestProver internal proverB;
    EcoProver internal aggregator;

    address internal creator;
    address internal solver;
    address internal attacker;

    uint64 internal constant DESTINATION = 8453;
    uint64 internal constant WRONG_DESTINATION = 999;
    uint256 internal constant REWARD = 1 ether;

    function setUp() public {
        creator = makeAddr("creator");
        solver = makeAddr("solver");
        attacker = makeAddr("attacker");

        portal = new Portal(address(0));
        proverA = new TestProver(address(portal));
        proverB = new TestProver(address(portal));

        bytes32[] memory members = new bytes32[](2);
        members[0] = bytes32(uint256(uint160(address(proverA))));
        members[1] = bytes32(uint256(uint160(address(proverB))));
        aggregator = new EcoProver(members);

        vm.deal(creator, 100 ether);
    }

    function _intent(
        address proverAddr,
        bytes32 saltValue
    ) internal view returns (Intent memory) {
        return
            Intent({
                destination: DESTINATION,
                route: Route({
                    salt: saltValue,
                    deadline: uint64(block.timestamp + 1000),
                    portal: address(portal),
                    nativeAmount: 0,
                    tokens: new TokenAmount[](0),
                    calls: new Call[](0)
                }),
                reward: Reward({
                    deadline: uint64(block.timestamp + 1000),
                    creator: creator,
                    prover: proverAddr,
                    nativeAmount: REWARD,
                    tokens: new TokenAmount[](0)
                })
            });
    }

    function _publish(
        Intent memory intent
    ) internal returns (bytes32 intentHash, bytes32 routeHash) {
        (intentHash, routeHash, ) = portal.getIntentHash(intent);
        vm.prank(creator);
        portal.publishAndFund{value: REWARD}(intent, false);
    }

    function test_withdraw_paysWhenAnyMemberHasProven() public {
        Intent memory intent = _intent(
            address(aggregator),
            bytes32(uint256(1))
        );
        (bytes32 intentHash, bytes32 routeHash) = _publish(intent);

        // Only the SECOND member proves — union semantics must still settle
        proverB.addProvenIntent(intentHash, solver, DESTINATION);

        uint256 before = solver.balance;
        portal.withdraw(DESTINATION, routeHash, intent.reward);
        assertEq(solver.balance - before, REWARD);
    }

    function test_withdraw_selfHealsAcrossTwoTransactions() public {
        Intent memory intent = _intent(
            address(aggregator),
            bytes32(uint256(2))
        );
        (bytes32 intentHash, bytes32 routeHash) = _publish(intent);

        // Member 0 lies about the destination and sorts first
        proverA.addProvenIntent(intentHash, attacker, WRONG_DESTINATION);
        proverB.addProvenIntent(intentHash, solver, DESTINATION);

        uint256 before = solver.balance;

        // First withdraw: pays nothing, forwards the challenge
        portal.withdraw(DESTINATION, routeHash, intent.reward);
        assertEq(solver.balance, before, "must not pay on first call");
        assertEq(attacker.balance, 0, "must never pay the attacker");
        assertEq(
            proverA.provenIntents(intentHash).claimant,
            address(0),
            "liar's proof must be deleted"
        );

        // Second withdraw: honest proof now sorts first and pays
        portal.withdraw(DESTINATION, routeHash, intent.reward);
        assertEq(solver.balance - before, REWARD);
    }

    function test_batchWithdraw_oneBadIntentDoesNotBlockTheOthers() public {
        Intent memory i1 = _intent(address(aggregator), bytes32(uint256(11)));
        Intent memory i2 = _intent(address(aggregator), bytes32(uint256(12)));
        Intent memory i3 = _intent(address(aggregator), bytes32(uint256(13)));

        (bytes32 h1, bytes32 r1) = _publish(i1);
        (bytes32 h2, bytes32 r2) = _publish(i2);
        (bytes32 h3, bytes32 r3) = _publish(i3);

        proverA.addProvenIntent(h1, solver, DESTINATION);
        proverA.addProvenIntent(h2, attacker, WRONG_DESTINATION); // poisoned
        proverB.addProvenIntent(h2, solver, DESTINATION);
        proverA.addProvenIntent(h3, solver, DESTINATION);

        uint64[] memory destinations = new uint64[](3);
        destinations[0] = DESTINATION;
        destinations[1] = DESTINATION;
        destinations[2] = DESTINATION;

        bytes32[] memory routeHashes = new bytes32[](3);
        routeHashes[0] = r1;
        routeHashes[1] = r2;
        routeHashes[2] = r3;

        Reward[] memory rewards = new Reward[](3);
        rewards[0] = i1.reward;
        rewards[1] = i2.reward;
        rewards[2] = i3.reward;

        uint256 before = solver.balance;

        // Must NOT revert; the poisoned entry is challenged and skipped
        portal.batchWithdraw(destinations, routeHashes, rewards);
        assertEq(solver.balance - before, REWARD * 2, "two of three paid");

        // The poisoned one now settles on its own
        portal.withdraw(DESTINATION, r2, i2.reward);
        assertEq(solver.balance - before, REWARD * 3);
    }

    function test_refund_worksAfterDeadlineWithCodelessMember() public {
        bytes32[] memory members = new bytes32[](2);
        members[0] = bytes32(uint256(uint160(address(0xDEAD)))); // codeless
        members[1] = bytes32(uint256(uint160(address(proverB))));
        EcoProver agg = new EcoProver(members);

        Intent memory intent = _intent(address(agg), bytes32(uint256(3)));
        (, bytes32 routeHash) = _publish(intent);

        vm.warp(block.timestamp + 2000);

        uint256 before = creator.balance;
        portal.refund(DESTINATION, routeHash, intent.reward);
        assertEq(creator.balance - before, REWARD);
    }

    function test_refund_blockedBeforeDeadlineWhenMemberHasProof() public {
        Intent memory intent = _intent(
            address(aggregator),
            bytes32(uint256(4))
        );
        (bytes32 intentHash, bytes32 routeHash) = _publish(intent);

        proverB.addProvenIntent(intentHash, solver, DESTINATION);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.IntentNotClaimed.selector,
                intentHash
            )
        );
        portal.refund(DESTINATION, routeHash, intent.reward);
    }

    /// @notice CHARACTERIZATION TEST — pins a KNOWN LIMITATION, not desired behaviour.
    /// @dev A member holding an entry whose `destination` is wrong shadows a valid proof
    ///      held by a lower-priority member, because `provenIntents` returns the first
    ///      non-zero claimant. This bug class does not exist for a single prover, which
    ///      stores exactly one `ProofData` per `intentHash`. `IntentSource.withdraw`
    ///      recovers — it forwards a challenge on its wrong-destination branch, so a second
    ///      `withdraw` pays — but `_validateRefund` reads the same shadowed value, never
    ///      forwards a challenge, and past `reward.deadline` refunds the creator while the
    ///      solver who delivered goes unpaid. The mitigation is deploy-time membership
    ///      validation (`Deploy.validateEcoProverMembers`), which restricts members to
    ///      provers whose `destination` is bridge-attested by
    ///      `MessageBridgeProver._handleCrossChainMessage`; the asymmetry itself remains in
    ///      `IntentSource`.
    ///      When that asymmetry is fixed, this test MUST be updated to assert the fixed
    ///      behaviour.
    function test_refund_shadowedProofRefundsCreator_knownLimitation() public {
        Intent memory intent = _intent(
            address(aggregator),
            bytes32(uint256(5))
        );
        (bytes32 intentHash, bytes32 routeHash) = _publish(intent);

        // Member 0 (proverA) holds a wrong-destination entry that shadows member 1's valid proof
        proverA.addProvenIntent(intentHash, attacker, WRONG_DESTINATION);
        proverB.addProvenIntent(intentHash, solver, DESTINATION);

        vm.warp(block.timestamp + 2000);

        uint256 creatorBefore = creator.balance;
        uint256 solverBefore = solver.balance;

        // Refund succeeds — the shadowed valid proof is never surfaced to the refund path
        portal.refund(DESTINATION, routeHash, intent.reward);

        assertEq(
            creator.balance - creatorBefore,
            REWARD,
            "creator wrongly refunded"
        );
        assertEq(
            solver.balance,
            solverBefore,
            "solver never paid despite valid proof"
        );
    }
}
