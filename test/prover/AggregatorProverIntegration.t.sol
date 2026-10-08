// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {AggregatorProver} from "../../contracts/prover/AggregatorProver.sol";
import {Portal} from "../../contracts/Portal.sol";
import {TestProver} from "../../contracts/test/TestProver.sol";
import {RevertingProver} from "../../contracts/test/RevertingProver.sol";
import {HyperProver} from "../../contracts/prover/HyperProver.sol";
import {TestMailbox} from "../../contracts/test/TestMailbox.sol";
import {PolymerProver} from "../../contracts/prover/PolymerProver.sol";
import {TestCrossL2ProverV2} from "../../contracts/test/TestCrossL2ProverV2.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {Intent, Route, Reward, TokenAmount, Call, CANCELLED_CLAIMANT, CANCELLED_CLAIMANT_BYTES32} from "../../contracts/types/Intent.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {IMessageBridgeProver} from "../../contracts/interfaces/IMessageBridgeProver.sol";

contract AggregatorProverIntegrationTest is Test {
    Portal internal portal;
    TestProver internal proverA;
    TestProver internal proverB;
    AggregatorProver internal aggregator;

    // Aggregator whose second member is a real HyperProver, so proofs reach it
    // through the bridge receive path instead of TestProver storage helpers
    TestMailbox internal mailbox;
    HyperProver internal hyperMember;
    AggregatorProver internal hyperAggregator;
    address internal hyperSourceProver;

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
        aggregator = new AggregatorProver(members);

        hyperSourceProver = makeAddr("hyperSourceProver");
        mailbox = new TestMailbox(address(0));
        bytes32[] memory hyperProvers = new bytes32[](1);
        hyperProvers[0] = bytes32(uint256(uint160(hyperSourceProver)));
        hyperMember = new HyperProver(
            address(mailbox),
            address(portal),
            hyperProvers,
            new IMessageBridgeProver.Domain[](0)
        );
        members[1] = bytes32(uint256(uint160(address(hyperMember))));
        hyperAggregator = new AggregatorProver(members);

        vm.deal(creator, 100 ether);
    }

    /// @dev Delivers a CANCELLED proof for `intentHash` from DESTINATION to the
    ///      HyperProver member through the mailbox
    function _handleHyperCancellation(bytes32 intentHash) internal {
        vm.prank(address(mailbox));
        hyperMember.handle(
            uint32(DESTINATION),
            bytes32(uint256(uint160(hyperSourceProver))),
            abi.encodePacked(
                DESTINATION,
                intentHash,
                CANCELLED_CLAIMANT_BYTES32
            )
        );
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

    /// @dev Previously used a codeless member as the misbehaving entry; the
    ///      constructor now rejects those, so a REVERTING member carries the
    ///      same case. What is being pinned is unchanged: a misbehaving
    ///      higher-priority member must not block refund after the deadline.
    function test_refund_worksAfterDeadlineWithMisbehavingMember() public {
        RevertingProver bad = new RevertingProver();
        bytes32[] memory members = new bytes32[](2);
        members[0] = bytes32(uint256(uint160(address(bad))));
        members[1] = bytes32(uint256(uint160(address(proverB))));
        AggregatorProver agg = new AggregatorProver(members);

        Intent memory intent = _intent(address(agg), bytes32(uint256(3)));
        (, bytes32 routeHash) = _publish(intent);

        vm.warp(block.timestamp + 2000);

        uint256 before = creator.balance;
        portal.refund(DESTINATION, routeHash, intent.reward);
        assertEq(creator.balance - before, REWARD);
    }

    function test_refund_beforeDeadlineOnMemberProvenCancellation() public {
        Intent memory intent = _intent(
            address(hyperAggregator),
            bytes32(uint256(6))
        );
        (bytes32 intentHash, bytes32 routeHash) = _publish(intent);

        // Only the lower-priority member holds the cancellation
        _handleHyperCancellation(intentHash);
        assertLt(block.timestamp, intent.reward.deadline);

        uint256 before = creator.balance;
        vm.prank(attacker);
        portal.refund(DESTINATION, routeHash, intent.reward);

        assertEq(creator.balance - before, REWARD);
        assertEq(
            uint256(portal.getRewardStatus(intentHash)),
            uint256(IIntentSource.Status.Refunded)
        );
    }

    function test_withdraw_revertsOnMemberProvenCancellation() public {
        Intent memory intent = _intent(
            address(hyperAggregator),
            bytes32(uint256(7))
        );
        (bytes32 intentHash, bytes32 routeHash) = _publish(intent);
        _handleHyperCancellation(intentHash);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.CancelledIntent.selector,
                intentHash
            )
        );
        vm.prank(solver);
        portal.withdraw(DESTINATION, routeHash, intent.reward);

        assertTrue(portal.isIntentFunded(intent));
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
    ///      validation (`Deploy.validateAggregatorProverMembers`), which restricts members to
    ///      provers whose `destination` is attested (by
    ///      `MessageBridgeProver._handleCrossChainMessage`, or by `PolymerProver.validate`'s
    ///      header check); the asymmetry itself remains in `IntentSource`.
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

    /// @dev Before `reward.deadline` a wrong-destination Cancelled entry does not open
    ///      the fast refund path, even though it shadows the valid member proof
    function test_refund_wrongDestinationCancellationBlockedBeforeDeadline()
        public
    {
        Intent memory intent = _intent(
            address(aggregator),
            bytes32(uint256(20))
        );
        (bytes32 intentHash, bytes32 routeHash) = _publish(intent);

        proverA.addProvenIntent(
            intentHash,
            CANCELLED_CLAIMANT,
            WRONG_DESTINATION
        );
        proverB.addProvenIntent(intentHash, solver, DESTINATION);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidStatusForRefund.selector,
                IIntentSource.Status.Funded,
                block.timestamp,
                intent.reward.deadline
            )
        );
        portal.refund(DESTINATION, routeHash, intent.reward);

        assertTrue(portal.isIntentFunded(intent));
    }

    /// @notice CHARACTERIZATION TEST — pins a KNOWN LIMITATION, not desired behaviour.
    /// @dev The Cancelled variant of
    ///      test_refund_shadowedProofRefundsCreator_knownLimitation: a wrong-destination
    ///      Cancelled entry shadows exactly like a wrong-destination Fulfilled one. Past
    ///      `reward.deadline` the refund pays the creator once, and the valid proof that
    ///      surfaces after the challenge cannot release the escrow a second time.
    function test_refund_shadowedByWrongDestinationCancellation_knownLimitation()
        public
    {
        Intent memory intent = _intent(
            address(aggregator),
            bytes32(uint256(21))
        );
        (bytes32 intentHash, bytes32 routeHash) = _publish(intent);

        proverA.addProvenIntent(
            intentHash,
            CANCELLED_CLAIMANT,
            WRONG_DESTINATION
        );
        proverB.addProvenIntent(intentHash, solver, DESTINATION);

        vm.warp(intent.reward.deadline);

        uint256 creatorBefore = creator.balance;
        uint256 solverBefore = solver.balance;

        portal.refund(DESTINATION, routeHash, intent.reward);

        assertEq(creator.balance - creatorBefore, REWARD, "creator refunded");
        assertEq(
            uint256(portal.getRewardStatus(intentHash)),
            uint256(IIntentSource.Status.Refunded)
        );

        // First withdraw challenges the wrong-destination entry and pays nothing
        portal.withdraw(DESTINATION, routeHash, intent.reward);
        assertEq(
            proverA.provenIntents(intentHash).claimant,
            address(0),
            "wrong-destination cancellation must be deleted"
        );

        // The valid proof now surfaces, but the escrow was already released
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidStatusForWithdrawal.selector,
                IIntentSource.Status.Refunded
            )
        );
        portal.withdraw(DESTINATION, routeHash, intent.reward);

        assertEq(solver.balance, solverBefore, "solver unpaid");
        assertEq(address(portal.intentVaultAddress(intent)).balance, 0);
    }

    /// @dev Withdraw recovers from a wrong-destination Cancelled shadow the same way it
    ///      does from a Fulfilled one, before and after `reward.deadline`, and the paid
    ///      intent can no longer be refunded
    function test_withdraw_selfHealsPastWrongDestinationCancellation() public {
        _assertWithdrawSelfHealsPastCancellation(bytes32(uint256(22)), false);
        _assertWithdrawSelfHealsPastCancellation(bytes32(uint256(23)), true);
    }

    function _assertWithdrawSelfHealsPastCancellation(
        bytes32 salt,
        bool afterDeadline
    ) internal {
        Intent memory intent = _intent(address(aggregator), salt);
        (bytes32 intentHash, bytes32 routeHash) = _publish(intent);

        proverA.addProvenIntent(
            intentHash,
            CANCELLED_CLAIMANT,
            WRONG_DESTINATION
        );
        proverB.addProvenIntent(intentHash, solver, DESTINATION);

        if (afterDeadline) vm.warp(intent.reward.deadline);

        uint256 solverBefore = solver.balance;
        uint256 creatorBefore = creator.balance;

        // First withdraw: pays nothing, deletes the wrong-destination cancellation
        portal.withdraw(DESTINATION, routeHash, intent.reward);
        assertEq(solver.balance, solverBefore, "must not pay on first call");
        assertTrue(portal.isIntentFunded(intent));

        // Second withdraw: the valid proof sorts first and pays the solver once
        portal.withdraw(DESTINATION, routeHash, intent.reward);
        assertEq(solver.balance - solverBefore, REWARD);
        assertEq(
            uint256(portal.getRewardStatus(intentHash)),
            uint256(IIntentSource.Status.Withdrawn)
        );

        // Replayed withdraw and a later refund release nothing more
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidStatusForWithdrawal.selector,
                IIntentSource.Status.Withdrawn
            )
        );
        portal.withdraw(DESTINATION, routeHash, intent.reward);

        vm.warp(intent.reward.deadline);
        portal.refund(DESTINATION, routeHash, intent.reward);
        assertEq(
            creator.balance,
            creatorBefore,
            "creator must not be refunded"
        );
        assertEq(solver.balance - solverBefore, REWARD);
    }

    /// @dev A PolymerProver member ahead of `proverB`, proving through the real
    ///      validate() path against a stubbed CrossL2ProverV2
    function _polymerAggregator()
        internal
        returns (
            AggregatorProver agg,
            PolymerProver polymer,
            TestCrossL2ProverV2 crossL2,
            address emitter
        )
    {
        emitter = makeAddr("polymerDestinationProver");
        bytes32[] memory whitelist = new bytes32[](1);
        whitelist[0] = bytes32(uint256(uint160(emitter)));
        crossL2 = new TestCrossL2ProverV2(0, address(0), "", "");
        polymer = new PolymerProver(
            address(portal),
            address(crossL2),
            32 * 1024,
            1,
            1399811149,
            whitelist
        );

        bytes32[] memory members = new bytes32[](2);
        members[0] = bytes32(uint256(uint160(address(polymer))));
        members[1] = bytes32(uint256(uint160(address(proverB))));
        agg = new AggregatorProver(members);
    }

    /// @dev Stubs a Polymer-attested IntentFulfilledFromSource event: Polymer
    ///      attributes it to `attestedChain`; the destination Portal wrote
    ///      `headerChain` into the payload. Returns the proof to validate.
    function _stubPolymerEvent(
        TestCrossL2ProverV2 crossL2,
        address emitter,
        uint64 attestedChain,
        uint64 headerChain,
        bytes32 intentHash
    ) internal returns (bytes memory proof) {
        crossL2.setAll(
            uint32(attestedChain),
            emitter,
            abi.encodePacked(
                keccak256("IntentFulfilledFromSource(uint64,bytes)"),
                bytes32(block.chainid)
            ),
            abi.encodePacked(
                headerChain,
                intentHash,
                bytes32(uint256(uint160(solver)))
            )
        );
        // The stub's constructor entry is index 0; setAll appends index 1.
        proof = abi.encodePacked(uint256(1));
    }

    function test_polymerMember_recordsTheIntentsOwnDestination() public {
        (
            AggregatorProver agg,
            PolymerProver polymer,
            TestCrossL2ProverV2 crossL2,
            address emitter
        ) = _polymerAggregator();
        Intent memory intent = _intent(address(agg), bytes32(uint256(20)));
        (bytes32 intentHash, bytes32 routeHash) = _publish(intent);

        polymer.validate(
            _stubPolymerEvent(
                crossL2,
                emitter,
                DESTINATION,
                DESTINATION,
                intentHash
            )
        );

        IProver.ProofData memory proof = agg.provenIntents(intentHash);
        assertEq(proof.claimant, solver);
        assertEq(proof.destination, DESTINATION);

        // One withdraw pays: nothing to challenge out first.
        uint256 before = solver.balance;
        portal.withdraw(DESTINATION, routeHash, intent.reward);
        assertEq(solver.balance - before, REWARD);
    }

    /// @dev The shadowing precondition is an entry whose destination differs
    ///      from the intent's. Polymer cannot write one: a header that
    ///      disagrees with the attested chain reverts, so the valid proof of
    ///      the lower-priority member still blocks a late refund.
    function test_polymerMember_cannotShadowWithAWrongDestination() public {
        (
            AggregatorProver agg,
            PolymerProver polymer,
            TestCrossL2ProverV2 crossL2,
            address emitter
        ) = _polymerAggregator();
        Intent memory intent = _intent(address(agg), bytes32(uint256(21)));
        (bytes32 intentHash, bytes32 routeHash) = _publish(intent);
        proverB.addProvenIntent(intentHash, solver, DESTINATION);

        bytes memory proof = _stubPolymerEvent(
            crossL2,
            emitter,
            WRONG_DESTINATION,
            DESTINATION,
            intentHash
        );
        vm.expectRevert(PolymerProver.InvalidDestinationChain.selector);
        polymer.validate(proof);

        vm.warp(block.timestamp + 2000);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.IntentNotClaimed.selector,
                intentHash
            )
        );
        portal.refund(DESTINATION, routeHash, intent.reward);
    }
}
