// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {BaseTest} from "../BaseTest.sol";
import {IInbox} from "../../contracts/interfaces/IInbox.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../../contracts/types/Intent.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";

contract InboxTest is BaseTest {
    address internal solver;
    address internal recipient;

    function setUp() public override {
        super.setUp();
        solver = makeAddr("solver");
        recipient = makeAddr("recipient");

        _mintAndApprove(creator, MINT_AMOUNT);
        _mintAndApprove(solver, MINT_AMOUNT);
        _fundUserNative(creator, 10 ether);
        _fundUserNative(solver, 10 ether);

        // Approve portal for solver to transfer tokens
        vm.startPrank(solver);
        tokenA.approve(address(portal), MINT_AMOUNT * 10);
        tokenB.approve(address(portal), MINT_AMOUNT * 20);
        vm.stopPrank();
    }

    function testInboxExists() public view {
        assertTrue(address(portal) != address(0));
    }

    function testPortalBasicProperties() public view {
        // Test version from ISemver interface via portal
        assertEq(portal.version(), "2.6");
    }

    function testPortalCanReceiveIntents() public {
        Intent memory intent = _createIntent();
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(intent.destination, routeHash, rewardHash)
        );

        // This should not revert
        vm.prank(solver);
        portal.fulfill(
            intentHash,
            intent.route,
            rewardHash,
            bytes32(uint256(uint160(recipient)))
        );
    }

    function testPortalFulfillWithValidIntent() public {
        Intent memory intent = _createIntent();
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(intent.destination, routeHash, rewardHash)
        );

        vm.prank(solver);
        portal.fulfill(
            intentHash,
            intent.route,
            rewardHash,
            bytes32(uint256(uint160(recipient)))
        );

        // Verify tokens were transferred
        assertEq(tokenA.balanceOf(recipient), MINT_AMOUNT);
    }

    function testPortalFulfillRevertsWithInvalidIntent() public {
        Intent memory intent = _createIntent();
        intent.destination = 999; // Invalid destination
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(intent.destination, routeHash, rewardHash)
        );

        vm.expectRevert();
        vm.prank(solver);
        portal.fulfill(
            intentHash,
            intent.route,
            rewardHash,
            bytes32(uint256(uint160(recipient)))
        );
    }

    function testPortalFulfillWithMultipleTokens() public {
        Intent memory intent = _createIntentWithMultipleTokens();
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(intent.destination, routeHash, rewardHash)
        );

        vm.prank(solver);
        portal.fulfill(
            intentHash,
            intent.route,
            rewardHash,
            bytes32(uint256(uint160(recipient)))
        );

        // Verify all tokens were transferred
        assertEq(tokenA.balanceOf(recipient), MINT_AMOUNT);
        assertEq(tokenB.balanceOf(recipient), MINT_AMOUNT * 2);
    }

    function testPortalFulfillWithCalls() public {
        Intent memory intent = _createIntentWithCalls();
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(intent.destination, routeHash, rewardHash)
        );

        vm.prank(solver);
        portal.fulfill(
            intentHash,
            intent.route,
            rewardHash,
            bytes32(uint256(uint160(recipient)))
        );

        // Verify calls were executed
        assertEq(tokenA.balanceOf(recipient), MINT_AMOUNT);
    }

    function testPortalFulfillWithNativeEthToEOA() public {
        uint256 ethAmount = 1 ether;

        // Create intent with ETH transfer to EOA
        TokenAmount[] memory tokens = new TokenAmount[](0);

        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: recipient, data: "", value: ethAmount});

        Intent memory intent = Intent({
            destination: uint64(block.chainid),
            route: Route({
                salt: salt,
                deadline: uint64(expiry),
                portal: address(portal),
                tokens: tokens,
                calls: calls
            }),
            reward: Reward({
                deadline: uint64(expiry),
                creator: creator,
                prover: address(prover),
                nativeValue: 0,
                tokens: new TokenAmount[](0)
            })
        });

        // Fund the portal with ETH
        vm.deal(address(portal), ethAmount);

        uint256 initialBalance = recipient.balance;

        bytes32 routeHash = keccak256(abi.encode(intent.route));
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(intent.destination, routeHash, rewardHash)
        );

        vm.prank(solver);
        portal.fulfill(
            intentHash,
            intent.route,
            rewardHash,
            bytes32(uint256(uint160(recipient)))
        );

        // Verify ETH was transferred to EOA
        assertEq(recipient.balance, initialBalance + ethAmount);
    }

    function testPortalFulfillWithNonAddressClaimant() public {
        Intent memory intent = _createIntent();

        // Use non-address bytes32 claimant for cross-VM compatibility
        bytes32 nonAddressClaimant = keccak256("non-evm-claimant-identifier");

        bytes32 routeHash = keccak256(abi.encode(intent.route));
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(intent.destination, routeHash, rewardHash)
        );

        vm.prank(solver);
        portal.fulfill(
            intentHash,
            intent.route,
            rewardHash,
            nonAddressClaimant
        );

        // Verify tokens were transferred (should handle bytes32 claimant)
        assertEq(tokenA.balanceOf(recipient), MINT_AMOUNT);
    }

    function testFulfillAndProveIntegration() public {
        Intent memory intent = _createIntent();
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(intent.destination, routeHash, rewardHash)
        );
        bytes32 claimantBytes = bytes32(uint256(uint160(recipient)));

        vm.prank(solver);
        portal.fulfillAndProve(
            intentHash,
            intent.route,
            rewardHash,
            claimantBytes,
            address(prover),
            uint64(block.chainid),
            ""
        );

        // Verify tokens were transferred
        assertEq(tokenA.balanceOf(recipient), MINT_AMOUNT);

        // Verify intent was marked as fulfilled
        assertEq(portal.fulfilled(intentHash), claimantBytes);
    }

    function testInitiateProvingWithMultipleIntents() public {
        // First, mint more tokens for solver to fulfill multiple intents
        vm.startPrank(solver);
        tokenA.mint(solver, MINT_AMOUNT * 3);
        tokenA.approve(address(portal), MINT_AMOUNT * 3);
        vm.stopPrank();

        // First, fulfill some intents
        bytes32[] memory intentHashes = new bytes32[](3);

        // Create and fulfill 3 different intents
        for (uint256 i = 0; i < 3; i++) {
            Intent memory intent = _createIntent();
            // Make each intent unique by changing the salt
            intent.route.salt = keccak256(abi.encodePacked(salt, i));

            bytes32 routeHash = keccak256(abi.encode(intent.route));
            bytes32 rewardHash = keccak256(abi.encode(intent.reward));
            bytes32 intentHash = keccak256(
                abi.encodePacked(intent.destination, routeHash, rewardHash)
            );
            intentHashes[i] = intentHash;

            // Fulfill each intent
            vm.prank(solver);
            portal.fulfill(
                intentHash,
                intent.route,
                rewardHash,
                bytes32(uint256(uint160(recipient)))
            );
        }

        // Now initiate proving for all fulfilled intents
        vm.prank(solver);
        portal.prove{value: 1 ether}(
            uint64(block.chainid),
            address(prover),
            intentHashes,
            "test_data"
        );
    }

    function testFulfillRejectsAlreadyFulfilled() public {
        Intent memory intent = _createIntent();
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(intent.destination, routeHash, rewardHash)
        );
        bytes32 claimantBytes = bytes32(uint256(uint160(recipient)));

        // First fulfillment should succeed
        vm.prank(solver);
        portal.fulfill(intentHash, intent.route, rewardHash, claimantBytes);

        // Second fulfillment should revert
        vm.expectRevert();
        vm.prank(solver);
        portal.fulfill(intentHash, intent.route, rewardHash, claimantBytes);
    }

    function testFulfillWithInvalidPortalAddress() public {
        Intent memory intent = _createIntent();
        intent.route.portal = address(0x999); // Wrong portal address

        bytes32 routeHash = keccak256(abi.encode(intent.route));
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(intent.destination, routeHash, rewardHash)
        );

        vm.expectRevert();
        vm.prank(solver);
        portal.fulfill(
            intentHash,
            intent.route,
            rewardHash,
            bytes32(uint256(uint160(recipient)))
        );
    }

    function testFulfillEmitsCorrectEvent() public {
        Intent memory intent = _createIntent();
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(intent.destination, routeHash, rewardHash)
        );
        bytes32 claimantBytes = bytes32(uint256(uint160(recipient)));

        _expectEmit();
        emit IInbox.IntentFulfilled(intentHash, claimantBytes);

        vm.prank(solver);
        portal.fulfill(intentHash, intent.route, rewardHash, claimantBytes);
    }

    function testFulfillWithZeroClaimant() public {
        Intent memory intent = _createIntent();
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(intent.destination, routeHash, rewardHash)
        );

        vm.expectRevert();
        vm.prank(solver);
        portal.fulfill(intentHash, intent.route, rewardHash, bytes32(0));
    }

    function _createIntent() internal view returns (Intent memory) {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(tokenA), amount: MINT_AMOUNT});

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                recipient,
                MINT_AMOUNT
            ),
            value: 0
        });

        return
            Intent({
                destination: uint64(block.chainid),
                route: Route({
                    salt: salt,
                    deadline: uint64(expiry),
                    portal: address(portal),
                    tokens: tokens,
                    calls: calls
                }),
                reward: Reward({
                    deadline: uint64(expiry),
                    creator: creator,
                    prover: address(prover),
                    nativeValue: 0,
                    tokens: new TokenAmount[](0)
                })
            });
    }

    function _createIntentWithMultipleTokens()
        internal
        view
        returns (Intent memory)
    {
        TokenAmount[] memory tokens = new TokenAmount[](2);
        tokens[0] = TokenAmount({token: address(tokenA), amount: MINT_AMOUNT});
        tokens[1] = TokenAmount({
            token: address(tokenB),
            amount: MINT_AMOUNT * 2
        });

        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                recipient,
                MINT_AMOUNT
            ),
            value: 0
        });
        calls[1] = Call({
            target: address(tokenB),
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                recipient,
                MINT_AMOUNT * 2
            ),
            value: 0
        });

        return
            Intent({
                destination: uint64(block.chainid),
                route: Route({
                    salt: salt,
                    deadline: uint64(expiry),
                    portal: address(portal),
                    tokens: tokens,
                    calls: calls
                }),
                reward: Reward({
                    deadline: uint64(expiry),
                    creator: creator,
                    prover: address(prover),
                    nativeValue: 0,
                    tokens: new TokenAmount[](0)
                })
            });
    }

    function _createIntentWithCalls() internal view returns (Intent memory) {
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: address(tokenA), amount: MINT_AMOUNT});

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(tokenA),
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                recipient,
                MINT_AMOUNT
            ),
            value: 0
        });

        return
            Intent({
                destination: uint64(block.chainid),
                route: Route({
                    salt: salt,
                    deadline: uint64(expiry),
                    portal: address(portal),
                    tokens: tokens,
                    calls: calls
                }),
                reward: Reward({
                    deadline: uint64(expiry),
                    creator: creator,
                    prover: address(prover),
                    nativeValue: 0,
                    tokens: new TokenAmount[](0)
                })
            });
    }
}
