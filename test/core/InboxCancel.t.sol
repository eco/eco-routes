// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {IInbox} from "../../contracts/interfaces/IInbox.sol";
import {Intent, CANCELLED_CLAIMANT} from "../../contracts/types/Intent.sol";

contract InboxCancelTest is BaseTest {
    address internal solver;
    bytes32 internal solverClaimant;

    function setUp() public override {
        super.setUp();
        solver = makeAddr("solver");
        solverClaimant = bytes32(uint256(uint160(solver)));
        // intentSource and the Inbox are the same Portal, so this also
        // approves the Portal to pull the solver's route tokens
        _mintAndApprove(solver, MINT_AMOUNT);
    }

    // BaseTest's intent targets CHAIN_ID (a source-side fixture); the Inbox
    // hashes with block.chainid, so point the intent at this chain
    function _destinationIntent()
        internal
        view
        returns (
            Intent memory destIntent,
            bytes32 intentHash,
            bytes32 rewardHash
        )
    {
        destIntent = intent;
        destIntent.destination = uint64(block.chainid);
        rewardHash = keccak256(abi.encode(destIntent.reward));
        intentHash = keccak256(
            abi.encodePacked(
                destIntent.destination,
                keccak256(abi.encode(destIntent.route)),
                rewardHash
            )
        );
    }

    function testCancelledSentinelGolden() public view {
        assertEq(
            CANCELLED_CLAIMANT,
            0xa8aa898126679f5f179cb3a4e685056aec77686a83e2a6bdf37c6f71dd2fdb5f
        );
        assertEq(CANCELLED_CLAIMANT, keccak256("eco.portal.intent.cancelled"));
        // Never a valid EVM address, so pre-cancellation provers skip it
        assertTrue(uint256(CANCELLED_CLAIMANT) >> 160 != 0);
        assertEq(portal.CANCELLED(), CANCELLED_CLAIMANT);
    }

    function testCancelRevertsAtRouteDeadline() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(i.route.deadline);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.RouteNotExpired.selector,
                i.route.deadline
            )
        );
        portal.cancel(intentHash, i.route, rewardHash);
    }

    function testCancelSucceedsOneSecondAfterRouteDeadline() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(uint256(i.route.deadline) + 1);

        vm.expectEmit(true, true, true, true, address(portal));
        emit IInbox.IntentCancelled(intentHash);
        vm.prank(otherPerson);
        portal.cancel(intentHash, i.route, rewardHash);

        assertEq(portal.claimants(intentHash), CANCELLED_CLAIMANT);
    }

    function testFulfillStillSucceedsAtRouteDeadline() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(i.route.deadline);

        vm.prank(solver);
        portal.fulfill(intentHash, i.route, rewardHash, solverClaimant);

        assertEq(portal.claimants(intentHash), solverClaimant);
    }

    function testCancelRevertsAfterFulfill() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(i.route.deadline);
        vm.prank(solver);
        portal.fulfill(intentHash, i.route, rewardHash, solverClaimant);

        vm.warp(uint256(i.route.deadline) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.IntentAlreadyFulfilled.selector,
                intentHash
            )
        );
        portal.cancel(intentHash, i.route, rewardHash);
    }

    function testFulfillRevertsAfterCancelViaExpiry() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(uint256(i.route.deadline) + 1);
        portal.cancel(intentHash, i.route, rewardHash);

        vm.expectRevert(IInbox.IntentExpired.selector);
        vm.prank(solver);
        portal.fulfill(intentHash, i.route, rewardHash, solverClaimant);
    }

    // Defence in depth: even if the clock could run backwards, the stored
    // sentinel alone blocks a later fulfill
    function testFulfillRevertsOnCancelledRecordEvenWithinDeadline() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(uint256(i.route.deadline) + 1);
        portal.cancel(intentHash, i.route, rewardHash);

        vm.warp(i.route.deadline);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.IntentAlreadyFulfilled.selector,
                intentHash
            )
        );
        vm.prank(solver);
        portal.fulfill(intentHash, i.route, rewardHash, solverClaimant);
    }

    function testCancelRevertsWhenAlreadyCancelled() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(uint256(i.route.deadline) + 1);
        portal.cancel(intentHash, i.route, rewardHash);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.IntentAlreadyFulfilled.selector,
                intentHash
            )
        );
        portal.cancel(intentHash, i.route, rewardHash);
    }

    function testCancelRevertsOnWrongPortal() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        i.route.portal = address(0xdead);
        vm.warp(uint256(i.route.deadline) + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.InvalidPortal.selector,
                address(0xdead)
            )
        );
        portal.cancel(intentHash, i.route, rewardHash);
    }

    function testCancelRevertsOnHashMismatch() public {
        (Intent memory i, , bytes32 rewardHash) = _destinationIntent();
        bytes32 wrongHash = keccak256("wrong");
        vm.warp(uint256(i.route.deadline) + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IInbox.InvalidHash.selector, wrongHash)
        );
        portal.cancel(wrongHash, i.route, rewardHash);
    }

    function testFulfillRejectsCancelledSentinelClaimant() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();

        vm.expectRevert(IInbox.ReservedClaimant.selector);
        vm.prank(solver);
        portal.fulfill(intentHash, i.route, rewardHash, CANCELLED_CLAIMANT);
    }

    function testProveCarriesCancelledSentinel() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(uint256(i.route.deadline) + 1);
        portal.cancel(intentHash, i.route, rewardHash);

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = intentHash;

        vm.expectEmit(true, true, true, true, address(portal));
        emit IInbox.IntentProven(intentHash, CANCELLED_CLAIMANT);
        portal.prove(address(prover), uint64(block.chainid), hashes, "");

        assertEq(prover.argIntentHashes(0), intentHash);
        assertEq(prover.argClaimants(0), CANCELLED_CLAIMANT);
    }
}
