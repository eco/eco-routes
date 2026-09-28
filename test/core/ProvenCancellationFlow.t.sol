// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {IInbox} from "../../contracts/interfaces/IInbox.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {IMessageBridgeProver} from "../../contracts/interfaces/IMessageBridgeProver.sol";
import {HyperProver} from "../../contracts/prover/HyperProver.sol";
import {TestMailbox} from "../../contracts/test/TestMailbox.sol";
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

        _assertRefundsBeforeRewardDeadline(i);

        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.InvalidStatusForWithdrawal.selector,
                IIntentSource.Status.Refunded
            )
        );
        intentSource.withdraw(i.destination, routeHash, i.reward);
    }

    function testFrontRunCancelDoesNotBlockCancelAndProveRefund() public {
        (
            Intent memory i,
            ,
            bytes32 rewardHash,
            bytes32 intentHash
        ) = _sameChainIntent();
        _publishAndFund(i, false);

        vm.warp(uint256(i.route.deadline) + 1);
        vm.prank(otherPerson);
        portal.cancel(intentHash, i.route, rewardHash);

        portal.cancelAndProve(
            intentHash,
            i.route,
            rewardHash,
            address(prover),
            uint64(block.chainid),
            ""
        );

        _assertRefundsBeforeRewardDeadline(i);
    }

    // Real HyperProver dispatch -> TestMailbox -> handle, with a source bridge
    // domain that differs from any chain id. The loopback mailbox delivers with
    // the dispatched domain as origin; this chain's own id is registered as
    // another chain's domain, so dispatching to CHAIN_ID instead of
    // sourceChainDomainID fails the origin cross-check, and empty data fails
    // HyperProver's decode.
    function testCancelAndProveThroughHyperlaneRefundsBeforeRewardDeadline()
        public
    {
        uint64 sourceDomain = 7_777_777;
        bytes32 sourceProver = bytes32(
            uint256(uint160(makeAddr("sourceProver")))
        );
        TestMailbox mailbox = new TestMailbox(address(0));
        bytes32[] memory provers = new bytes32[](1);
        provers[0] = sourceProver;
        IMessageBridgeProver.Domain[]
            memory domains = new IMessageBridgeProver.Domain[](2);
        domains[0] = IMessageBridgeProver.Domain({
            domain: sourceDomain,
            chainId: uint64(block.chainid)
        });
        domains[1] = IMessageBridgeProver.Domain({
            domain: uint64(block.chainid),
            chainId: uint64(block.chainid) + 1
        });
        HyperProver hyperProver = new HyperProver(
            address(mailbox),
            address(portal),
            provers,
            domains
        );
        mailbox.setProcessor(address(hyperProver));

        (Intent memory i, , bytes32 rewardHash, ) = _sameChainIntent();
        i.reward.prover = address(hyperProver);
        i.reward.nativeAmount = REWARD_NATIVE_ETH;
        rewardHash = keccak256(abi.encode(i.reward));
        bytes32 intentHash = _hashIntent(i);
        _fundUserNative(creator, REWARD_NATIVE_ETH);
        _publishAndFundWithValue(i, false, REWARD_NATIVE_ETH);

        vm.warp(uint256(i.route.deadline) + 1);
        vm.deal(otherPerson, 1 ether);
        vm.prank(otherPerson);
        portal.cancelAndProve{value: mailbox.FEE()}(
            intentHash,
            i.route,
            rewardHash,
            address(hyperProver),
            sourceDomain,
            abi.encode(
                HyperProver.UnpackedData({
                    sourceChainProver: sourceProver,
                    metadata: "",
                    hookAddr: address(0)
                })
            )
        );

        assertEq(mailbox.destinationDomain(), sourceDomain);
        IProver.ProofData memory proof = hyperProver.provenIntents(intentHash);
        assertEq(uint8(proof.outcome), uint8(IProver.Outcome.Cancelled));
        assertEq(proof.destination, uint64(block.chainid));

        _assertRefundsBeforeRewardDeadline(i);
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
