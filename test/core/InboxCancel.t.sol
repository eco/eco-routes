// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Vm} from "forge-std/Test.sol";
import {BaseTest} from "../BaseTest.sol";
import {IInbox} from "../../contracts/interfaces/IInbox.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {Intent, CANCELLED_CLAIMANT, CANCELLED_CLAIMANT_BYTES32} from "../../contracts/types/Intent.sol";

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
        // Cross-VM pin: must equal eco-svm-std's CANCELLED byte for byte
        bytes32 golden = 0x000000000000000000000000e685056aec77686a83e2a6bdf37c6f71dd2fdb5f;
        assertEq(portal.CANCELLED(), golden);
        assertEq(
            portal.CANCELLED(),
            bytes32(
                uint256(
                    uint160(
                        address(
                            uint160(
                                uint256(
                                    keccak256("eco.portal.intent.cancelled")
                                )
                            )
                        )
                    )
                )
            )
        );
        assertEq(CANCELLED_CLAIMANT_BYTES32, golden);
        assertEq(
            CANCELLED_CLAIMANT,
            0xe685056aEc77686A83E2a6bDf37c6f71dD2fdB5f
        );
        // A valid EVM address, so every prover records it like any claimant
        assertEq(uint256(portal.CANCELLED()) >> 160, 0);
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

        assertEq(portal.claimants(intentHash), CANCELLED_CLAIMANT_BYTES32);
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
                IInbox.IntentAlreadyCancelled.selector,
                intentHash
            )
        );
        portal.cancel(intentHash, i.route, rewardHash);
    }

    function testCancelAndProveForwardsDomainDataAndValueToProver() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(uint256(i.route.deadline) + 1);
        vm.deal(otherPerson, 1 ether);
        // A domain distinct from the chain ID, so a swapped argument shows
        uint64 domain = 424242;
        bytes memory data = hex"c0ffee";

        vm.expectCall(
            address(prover),
            0.1 ether,
            abi.encodeCall(
                IProver.prove,
                (
                    otherPerson,
                    domain,
                    abi.encodePacked(
                        uint64(block.chainid),
                        intentHash,
                        CANCELLED_CLAIMANT_BYTES32
                    ),
                    data
                )
            )
        );
        vm.prank(otherPerson);
        portal.cancelAndProve{value: 0.1 ether}(
            intentHash,
            i.route,
            rewardHash,
            address(prover),
            domain,
            data
        );

        assertEq(prover.proveCallCount(), 1);
    }

    function testCancelAndProveAfterFrontRunCancelStillProves() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(uint256(i.route.deadline) + 1);
        vm.prank(otherPerson);
        portal.cancel(intentHash, i.route, rewardHash);

        vm.recordLogs();
        portal.cancelAndProve(
            intentHash,
            i.route,
            rewardHash,
            address(prover),
            uint64(block.chainid),
            ""
        );

        assertEq(portal.claimants(intentHash), CANCELLED_CLAIMANT_BYTES32);
        assertEq(prover.proveCallCount(), 1);
        assertEq(prover.argClaimants(0), CANCELLED_CLAIMANT_BYTES32);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 j = 0; j < logs.length; j++) {
            assertTrue(logs[j].topics[0] != IInbox.IntentCancelled.selector);
        }
    }

    function testCancelAndProveRevertsAfterFulfill() public {
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
        portal.cancelAndProve(
            intentHash,
            i.route,
            rewardHash,
            address(prover),
            uint64(block.chainid),
            ""
        );
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
        portal.fulfill(
            intentHash,
            i.route,
            rewardHash,
            CANCELLED_CLAIMANT_BYTES32
        );
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
        emit IInbox.IntentProven(intentHash, CANCELLED_CLAIMANT_BYTES32);
        portal.prove(address(prover), uint64(block.chainid), hashes, "");

        assertEq(prover.argIntentHashes(0), intentHash);
        assertEq(prover.argClaimants(0), CANCELLED_CLAIMANT_BYTES32);
    }

    function testCancelAndProveCancelsAndDispatchesSentinel() public {
        (
            Intent memory i,
            bytes32 intentHash,
            bytes32 rewardHash
        ) = _destinationIntent();
        vm.warp(uint256(i.route.deadline) + 1);
        vm.deal(otherPerson, 1 ether);

        vm.prank(otherPerson);
        portal.cancelAndProve{value: 0.1 ether}(
            intentHash,
            i.route,
            rewardHash,
            address(prover),
            uint64(block.chainid),
            "data"
        );

        assertEq(portal.claimants(intentHash), CANCELLED_CLAIMANT_BYTES32);
        assertEq(prover.proveCallCount(), 1);
        assertEq(prover.argIntentHashes(0), intentHash);
        assertEq(prover.argClaimants(0), CANCELLED_CLAIMANT_BYTES32);
        (address sender, uint64 sourceChainId, , uint256 value) = prover.args();
        assertEq(sender, otherPerson);
        assertEq(sourceChainId, uint64(block.chainid));
        assertEq(value, 0.1 ether);
        assertEq(address(portal).balance, 0);
    }

    function testCancelAndProveRevertsBeforeDeadline() public {
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
        portal.cancelAndProve(
            intentHash,
            i.route,
            rewardHash,
            address(prover),
            uint64(block.chainid),
            ""
        );
        assertEq(prover.proveCallCount(), 0);
    }
}
