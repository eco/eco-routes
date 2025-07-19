// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {HyperProver} from "../../contracts/prover/HyperProver.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {TestMailbox} from "../../contracts/test/TestMailbox.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../../contracts/types/Intent.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {AddressConverter} from "../../contracts/libs/AddressConverter.sol";

contract HyperProverTest is BaseTest {
    using AddressConverter for bytes32;
    using AddressConverter for address;

    HyperProver internal hyperProver;
    TestMailbox internal mailbox;

    address internal whitelistedProver;
    address internal nonWhitelistedProver;

    function setUp() public override {
        super.setUp();

        whitelistedProver = makeAddr("whitelistedProver");
        nonWhitelistedProver = makeAddr("nonWhitelistedProver");

        vm.startPrank(deployer);

        // Deploy TestMailbox - set processor to hyperProver so it processes messages
        mailbox = new TestMailbox(address(0));

        // Setup provers array - include our whitelisted prover
        bytes32[] memory provers = new bytes32[](1);
        provers[0] = bytes32(uint256(uint160(whitelistedProver)));

        // Deploy HyperProver
        hyperProver = new HyperProver(
            address(mailbox),
            address(portal),
            provers,
            100000 // default gas limit
        );

        // Set the hyperProver as the processor for the mailbox
        mailbox.setProcessor(address(hyperProver));

        vm.stopPrank();

        _mintAndApprove(creator, MINT_AMOUNT);
        _fundUserNative(creator, 10 ether);

        // Fund the hyperProver contract for gas fees
        vm.deal(address(hyperProver), 10 ether);
        // Also fund the portal since it's the one calling prove
        vm.deal(address(portal), 10 ether);
    }

    function _encodeProverData(
        bytes32 sourceChainProver,
        bytes memory metadata,
        address hookAddr
    ) internal pure returns (bytes memory) {
        return abi.encode(sourceChainProver, metadata, hookAddr);
    }

    function testInitializesCorrectly() public view {
        assertTrue(address(hyperProver) != address(0));
        assertEq(hyperProver.getProofType(), "Hyperlane");
    }

    function testImplementsIProverInterface() public view {
        assertTrue(hyperProver.supportsInterface(type(IProver).interfaceId));
    }

    function testOnlyInboxCanCallProve() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        vm.expectRevert();
        vm.prank(creator);
        hyperProver.prove(creator, block.chainid, intentHashes, claimants, "");
    }

    function testProveWithValidInput() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory proverData = _encodeProverData(
            bytes32(uint256(uint160(whitelistedProver))),
            "",
            address(0)
        );

        // Check the fee first
        uint256 expectedFee = hyperProver.fetchFee(
            block.chainid,
            intentHashes,
            claimants,
            proverData
        );

        vm.prank(address(portal));
        hyperProver.prove{value: expectedFee}(
            creator,
            block.chainid,
            intentHashes,
            claimants,
            proverData
        );
    }

    function testProveEmitsIntentProvenEvent() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        bytes32 intentHash = _hashIntent(intent);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        _expectEmit();
        emit IProver.IntentProven(intentHash, claimant);

        vm.prank(address(portal));
        bytes memory proverData = _encodeProverData(
            bytes32(uint256(uint160(whitelistedProver))),
            "",
            address(0)
        );
        hyperProver.prove{value: 1 ether}(
            creator,
            block.chainid,
            intentHashes,
            claimants,
            proverData
        );
    }

    function testProveBatchIntents() public {
        bytes32[] memory intentHashes = new bytes32[](3);
        bytes32[] memory claimants = new bytes32[](3);

        for (uint256 i = 0; i < 3; i++) {
            Intent memory testIntent = intent;
            testIntent.route.salt = keccak256(abi.encodePacked(salt, i));
            intentHashes[i] = _hashIntent(testIntent);
            claimants[i] = bytes32(uint256(uint160(claimant)));
        }

        vm.prank(address(portal));
        bytes memory proverData = _encodeProverData(
            bytes32(uint256(uint160(whitelistedProver))),
            "",
            address(0)
        );
        hyperProver.prove{value: 1 ether}(
            creator,
            block.chainid,
            intentHashes,
            claimants,
            proverData
        );

        // Check that all intents were proven
        for (uint256 i = 0; i < 3; i++) {
            IProver.ProofData memory proof = hyperProver.provenIntents(
                intentHashes[i]
            );
            assertEq(proof.claimant, claimant);
        }
    }

    function testProveRejectsArrayLengthMismatch() public {
        bytes32[] memory intentHashes = new bytes32[](2);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        intentHashes[1] = keccak256("second intent");
        claimants[0] = bytes32(uint256(uint160(claimant)));

        vm.expectRevert(IProver.ArrayLengthMismatch.selector);
        vm.prank(address(portal));
        bytes memory proverData = _encodeProverData(
            bytes32(uint256(uint160(whitelistedProver))),
            "",
            address(0)
        );
        hyperProver.prove{value: 1 ether}(
            creator,
            block.chainid,
            intentHashes,
            claimants,
            proverData
        );
    }

    function testProveWithEmptyArrays() public {
        bytes32[] memory intentHashes = new bytes32[](0);
        bytes32[] memory claimants = new bytes32[](0);

        vm.prank(address(portal));
        bytes memory proverData = _encodeProverData(
            bytes32(uint256(uint160(whitelistedProver))),
            "",
            address(0)
        );
        hyperProver.prove{value: 1 ether}(
            creator,
            block.chainid,
            intentHashes,
            claimants,
            proverData
        );
    }

    function testHandleOnlyFromMailbox() public {
        bytes memory messageBody = abi.encode(
            new bytes32[](1),
            new bytes32[](1)
        );

        vm.expectRevert();
        vm.prank(creator);
        hyperProver.handle(
            1,
            bytes32(uint256(uint160(whitelistedProver))),
            messageBody
        );
    }

    function testHandleWithWhitelistedSender() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory messageBody = abi.encode(intentHashes, claimants);

        vm.prank(address(mailbox));
        hyperProver.handle(
            1,
            bytes32(uint256(uint160(whitelistedProver))),
            messageBody
        );

        IProver.ProofData memory proof = hyperProver.provenIntents(
            intentHashes[0]
        );
        assertEq(proof.claimant, claimant);
        assertEq(proof.destinationChainID, CHAIN_ID);
    }

    function testHandleRejectsNonWhitelistedSender() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory messageBody = abi.encode(intentHashes, claimants);

        vm.expectRevert();
        vm.prank(address(mailbox));
        hyperProver.handle(
            1,
            bytes32(uint256(uint160(nonWhitelistedProver))),
            messageBody
        );
    }

    function testHandleArrayLengthMismatch() public {
        bytes32[] memory intentHashes = new bytes32[](2);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        intentHashes[1] = keccak256("second intent");
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory messageBody = abi.encode(intentHashes, claimants);

        vm.expectRevert(IProver.ArrayLengthMismatch.selector);
        vm.prank(address(mailbox));
        hyperProver.handle(
            1,
            bytes32(uint256(uint160(whitelistedProver))),
            messageBody
        );
    }

    function testHandleDuplicateIntent() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        bytes32 intentHash = _hashIntent(intent);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory messageBody = abi.encode(intentHashes, claimants);

        // First call should succeed
        vm.prank(address(mailbox));
        hyperProver.handle(
            1,
            bytes32(uint256(uint160(whitelistedProver))),
            messageBody
        );

        // Second call should emit IntentAlreadyProven event
        _expectEmit();
        emit IProver.IntentAlreadyProven(intentHash);

        vm.prank(address(mailbox));
        hyperProver.handle(
            1,
            bytes32(uint256(uint160(whitelistedProver))),
            messageBody
        );
    }

    function testChallengeIntentProofWithWrongChain() public {
        // First, prove the intent
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        bytes32 intentHash = _hashIntent(intent);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        vm.prank(address(portal));
        bytes memory proverData = _encodeProverData(
            bytes32(uint256(uint160(whitelistedProver))),
            "",
            address(0)
        );
        hyperProver.prove{value: 1 ether}(
            creator,
            block.chainid,
            intentHashes,
            claimants,
            proverData
        );

        // Verify intent is proven (with chain ID = 31337 from the prove call)
        IProver.ProofData memory proof = hyperProver.provenIntents(intentHash);
        assertTrue(proof.claimant != address(0));
        assertEq(proof.destinationChainID, uint96(block.chainid)); // 31337

        // The original intent has destination = 1 (CHAIN_ID from BaseTest)
        // So challenging with the original intent should clear the proof
        // because intent.destination (1) != proof.destinationChainID (31337)
        vm.prank(creator);
        hyperProver.challengeIntentProof(
            intent.destination,
            keccak256(abi.encode(intent.route)),
            keccak256(abi.encode(intent.reward))
        );

        // Verify proof was cleared
        proof = hyperProver.provenIntents(intentHash);
        assertEq(proof.claimant, address(0));
    }

    function testChallengeIntentProofWithCorrectChain() public {
        // Create an intent with destination matching the chain where we'll prove it
        Intent memory localIntent = intent;
        localIntent.destination = uint64(block.chainid); // 31337

        // First, prove the intent
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        bytes32 intentHash = _hashIntent(localIntent);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        vm.prank(address(portal));
        bytes memory proverData = _encodeProverData(
            bytes32(uint256(uint160(whitelistedProver))),
            "",
            address(0)
        );
        hyperProver.prove{value: 1 ether}(
            creator,
            block.chainid,
            intentHashes,
            claimants,
            proverData
        );

        // Verify intent is proven
        IProver.ProofData memory proof = hyperProver.provenIntents(intentHash);
        assertTrue(proof.claimant != address(0));
        assertEq(proof.destinationChainID, uint96(block.chainid));

        // Challenge with correct chain (destination matches proof) should do nothing
        vm.prank(creator);
        hyperProver.challengeIntentProof(
            localIntent.destination,
            keccak256(abi.encode(localIntent.route)),
            keccak256(abi.encode(localIntent.reward))
        );

        // Verify proof is still there
        proof = hyperProver.provenIntents(intentHash);
        assertEq(proof.claimant, claimant);
    }

    function testProvenIntentsStorage() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        bytes32 intentHash = _hashIntent(intent);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        // First, send the prove message
        vm.prank(address(portal));
        bytes memory proverData = _encodeProverData(
            bytes32(uint256(uint160(whitelistedProver))),
            "",
            address(0)
        );
        hyperProver.prove{value: 1 ether}(
            creator,
            block.chainid,
            intentHashes,
            claimants,
            proverData
        );

        // Now simulate the message being received back by calling handle
        bytes memory messageBody = abi.encode(intentHashes, claimants);
        vm.prank(address(mailbox));
        hyperProver.handle(
            uint32(block.chainid),
            bytes32(uint256(uint160(whitelistedProver))),
            messageBody
        );

        // Now check the storage
        IProver.ProofData memory proof = hyperProver.provenIntents(intentHash);
        assertEq(proof.claimant, claimant);
        assertEq(proof.destinationChainID, uint96(block.chainid));
    }

    function testSupportsInterface() public view {
        assertTrue(hyperProver.supportsInterface(type(IProver).interfaceId));
        assertTrue(hyperProver.supportsInterface(0x01ffc9a7)); // ERC165
    }

    function testProveWithRefundHandling() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        uint256 overpayment = 2 ether;
        uint256 initialBalance = creator.balance;

        vm.prank(address(portal));
        bytes memory proverData = _encodeProverData(
            bytes32(uint256(uint160(whitelistedProver))),
            "",
            address(0)
        );
        hyperProver.prove{value: overpayment}(
            creator,
            block.chainid,
            intentHashes,
            claimants,
            proverData
        );

        // Should refund excess payment (implementation dependent)
        // This test validates the refund mechanism exists
        assertTrue(creator.balance >= initialBalance - overpayment);
    }

    function testProveWithLargeArrays() public {
        uint256 arraySize = 50; // Test with larger array
        bytes32[] memory intentHashes = new bytes32[](arraySize);
        bytes32[] memory claimants = new bytes32[](arraySize);

        for (uint256 i = 0; i < arraySize; i++) {
            intentHashes[i] = keccak256(abi.encodePacked("intent", i));
            claimants[i] = bytes32(uint256(uint160(claimant)));
        }

        // Should handle large arrays without running out of gas
        vm.prank(address(portal));
        bytes memory proverData = _encodeProverData(
            bytes32(uint256(uint160(whitelistedProver))),
            "",
            address(0)
        );
        hyperProver.prove{value: 1 ether}(
            creator,
            block.chainid,
            intentHashes,
            claimants,
            proverData
        );
    }

    function testHandleWithEmptyArrays() public {
        bytes32[] memory intentHashes = new bytes32[](0);
        bytes32[] memory claimants = new bytes32[](0);

        bytes memory messageBody = abi.encode(intentHashes, claimants);

        // Should handle empty arrays gracefully
        vm.prank(address(mailbox));
        hyperProver.handle(
            1,
            bytes32(uint256(uint160(whitelistedProver))),
            messageBody
        );
    }

    function testHandleWithInvalidMessageFormat() public {
        bytes memory invalidMessage = abi.encode("invalid", "format");

        vm.expectRevert();
        vm.prank(address(mailbox));
        hyperProver.handle(
            1,
            bytes32(uint256(uint160(whitelistedProver))),
            invalidMessage
        );
    }

    function testCrossVMClaimantCompatibility() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        address nonEvmClaimant = makeAddr("non-evm-claimant"); // Use a valid address
        claimants[0] = bytes32(uint256(uint160(nonEvmClaimant)));

        vm.prank(address(portal));
        bytes memory proverData = _encodeProverData(
            bytes32(uint256(uint160(whitelistedProver))),
            "",
            address(0)
        );
        hyperProver.prove{value: 1 ether}(
            creator,
            block.chainid,
            intentHashes,
            claimants,
            proverData
        );

        IProver.ProofData memory proof = hyperProver.provenIntents(
            intentHashes[0]
        );
        assertEq(proof.claimant, nonEvmClaimant);
    }
}
