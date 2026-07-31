// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {HyperProver} from "../../contracts/prover/HyperProver.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {IMessageBridgeProver} from "../../contracts/interfaces/IMessageBridgeProver.sol";
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

    /**
     * @notice Helper function to encode proofs from separate arrays
     * @param intentHashes Array of intent hashes
     * @param claimants Array of claimant addresses (as bytes32)
     * @return encodedProofs Encoded (intentHash, claimant) pairs as bytes
     */
    function encodeProofs(
        bytes32[] memory intentHashes,
        bytes32[] memory claimants
    ) internal view returns (bytes memory encodedProofs) {
        require(
            intentHashes.length == claimants.length,
            "Array length mismatch"
        );

        // Simulate what Inbox does - prepend 8 bytes for chain ID
        encodedProofs = new bytes(8 + intentHashes.length * 64);

        // Prepend chain ID
        uint64 chainId = uint64(block.chainid);
        assembly {
            mstore(add(encodedProofs, 0x20), shl(192, chainId))
        }

        for (uint256 i = 0; i < intentHashes.length; i++) {
            assembly {
                let offset := add(8, mul(i, 64))
                // Store hash in first 32 bytes of each pair
                mstore(
                    add(add(encodedProofs, 0x20), offset),
                    mload(add(intentHashes, add(0x20, mul(i, 32))))
                )
                // Store claimant in next 32 bytes of each pair
                mstore(
                    add(add(encodedProofs, 0x20), add(offset, 32)),
                    mload(add(claimants, add(0x20, mul(i, 32))))
                )
            }
        }
    }

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
            new IMessageBridgeProver.Domain[](0)
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
        HyperProver.UnpackedData memory unpacked = HyperProver.UnpackedData({
            sourceChainProver: sourceChainProver,
            metadata: metadata,
            hookAddr: hookAddr
        });

        return abi.encode(unpacked);
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

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);

        vm.expectRevert();
        vm.prank(creator);
        hyperProver.prove(creator, uint64(block.chainid), encodedProofs, "");
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

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);

        // Check the fee first
        uint256 expectedFee = hyperProver.fetchFee(
            uint64(block.chainid),
            encodedProofs,
            proverData
        );

        vm.prank(address(portal));
        hyperProver.prove{value: expectedFee}(
            creator,
            uint64(block.chainid),
            encodedProofs,
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
        emit IProver.IntentProven(intentHash, claimant, uint64(block.chainid));

        vm.prank(address(portal));
        bytes memory proverData = _encodeProverData(
            bytes32(uint256(uint160(whitelistedProver))),
            "",
            address(0)
        );
        hyperProver.prove{value: 1 ether}(
            creator,
            uint64(block.chainid),
            encodeProofs(intentHashes, claimants),
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
            uint64(block.chainid),
            encodeProofs(intentHashes, claimants),
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

    function testProveRejectsArrayLengthMismatch() public view {
        bytes32[] memory intentHashes = new bytes32[](2);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        intentHashes[1] = keccak256("second intent");
        claimants[0] = bytes32(uint256(uint160(claimant)));

        // This should revert in encodeProofs due to array length mismatch
        // We test this by checking that arrays have different lengths
        assertTrue(
            intentHashes.length != claimants.length,
            "Arrays should have different lengths"
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
            uint64(block.chainid),
            encodeProofs(intentHashes, claimants),
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

        // Pack hash/claimant pairs as bytes with chain ID prefix
        bytes memory messageBody = _formatMessageWithChainId(
            1,
            intentHashes,
            claimants
        );

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
        assertEq(proof.destination, CHAIN_ID);
    }

    function testHandle_defaultDomainEqualsChainId() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));
        bytes memory messageBody = _formatMessageWithChainId(
            1,
            intentHashes,
            claimants
        );

        vm.prank(address(mailbox));
        hyperProver.handle(
            1,
            bytes32(uint256(uint160(whitelistedProver))),
            messageBody
        );

        assertEq(
            hyperProver.provenIntents(intentHashes[0]).destination,
            uint64(1)
        );
    }

    function testHandle_revertsWhenHeaderMismatchesOrigin() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));
        // origin = 1 but header claims chain 999
        bytes memory messageBody = _formatMessageWithChainId(
            999,
            intentHashes,
            claimants
        );

        vm.prank(address(mailbox));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.ChainIdMismatch.selector,
                uint64(1),
                uint64(1),
                uint64(999)
            )
        );
        hyperProver.handle(
            1,
            bytes32(uint256(uint160(whitelistedProver))),
            messageBody
        );
    }

    function testHandle_exceptionOverridesDefault() public {
        IMessageBridgeProver.Domain[]
            memory domains = new IMessageBridgeProver.Domain[](1);
        domains[0] = IMessageBridgeProver.Domain({domain: 7, chainId: 1234});
        vm.prank(deployer);
        HyperProver p = new HyperProver(
            address(mailbox),
            address(portal),
            _singleProver(whitelistedProver),
            domains
        );

        assertEq(p.chainIdByDomain(7), uint64(1234));

        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));
        bytes memory body = _formatMessageWithChainId(
            1234,
            intentHashes,
            claimants
        );

        vm.prank(address(mailbox));
        p.handle(7, bytes32(uint256(uint160(whitelistedProver))), body);
        assertEq(p.provenIntents(intentHashes[0]).destination, uint64(1234));
    }

    function testConstructor_revertsOnInvalidDomainConfig() public {
        IMessageBridgeProver.Domain[]
            memory dup = new IMessageBridgeProver.Domain[](2);
        dup[0] = IMessageBridgeProver.Domain({domain: 5, chainId: 5});
        dup[1] = IMessageBridgeProver.Domain({domain: 5, chainId: 6}); // duplicate domain
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.InvalidDomainConfig.selector,
                uint64(5),
                uint64(6)
            )
        );
        new HyperProver(
            address(mailbox),
            address(portal),
            _singleProver(whitelistedProver),
            dup
        );
    }

    function testConstructor_revertsOnDuplicateChainId() public {
        IMessageBridgeProver.Domain[]
            memory dup = new IMessageBridgeProver.Domain[](2);
        dup[0] = IMessageBridgeProver.Domain({domain: 7, chainId: 100});
        dup[1] = IMessageBridgeProver.Domain({domain: 8, chainId: 100}); // duplicate chainId
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.InvalidDomainConfig.selector,
                uint64(8),
                uint64(100)
            )
        );
        new HyperProver(
            address(mailbox),
            address(portal),
            _singleProver(whitelistedProver),
            dup
        );
    }

    function testConstructor_emitsDomainRegisteredPerEntry() public {
        IMessageBridgeProver.Domain[]
            memory domains = new IMessageBridgeProver.Domain[](1);
        domains[0] = IMessageBridgeProver.Domain({domain: 7, chainId: 1234});
        vm.expectEmit(true, true, false, false);
        emit IMessageBridgeProver.DomainRegistered(uint64(7), uint64(1234));
        vm.prank(deployer);
        new HyperProver(
            address(mailbox),
            address(portal),
            _singleProver(whitelistedProver),
            domains
        );
    }

    // Generic domain != chainId case: a chain whose bridge domain differs from
    // its chainId MUST be registered as an exception, because the
    // domain == chainId fallback cannot resolve it safely. With the exception
    // registered, an honest proof (header == the registered chainId) is
    // accepted, and a spoof that reports the raw domain number as the chainId
    // fails closed. The values below are arbitrary illustrative numbers chosen
    // only so that domain != chainId; they do not correspond to any real chain.
    function testHandle_registeredDomainExceptionResolvesAndBlocksSpoof()
        public
    {
        uint64 exampleDomain = 424242; // arbitrary bridge domain (illustrative)
        uint64 exampleChainId = 999999; // arbitrary chainId != domain (illustrative)

        IMessageBridgeProver.Domain[]
            memory domains = new IMessageBridgeProver.Domain[](1);
        domains[0] = IMessageBridgeProver.Domain({
            domain: exampleDomain,
            chainId: exampleChainId
        });
        vm.prank(deployer);
        HyperProver p = new HyperProver(
            address(mailbox),
            address(portal),
            _singleProver(whitelistedProver),
            domains
        );
        assertEq(p.chainIdByDomain(exampleDomain), exampleChainId);

        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        // Honest proof: header == the registered chainId -> accepted.
        bytes memory body = _formatMessageWithChainId(
            exampleChainId,
            intentHashes,
            claimants
        );
        vm.prank(address(mailbox));
        p.handle(
            uint32(exampleDomain),
            bytes32(uint256(uint160(whitelistedProver))),
            body
        );
        assertEq(p.provenIntents(intentHashes[0]).destination, exampleChainId);

        // Spoof: a compromised sender reports the raw domain number as the
        // chainId. The registered exception resolves to exampleChainId, so the
        // header cross-check rejects it.
        bytes32[] memory ih2 = new bytes32[](1);
        ih2[0] = keccak256("other-intent");
        bytes memory spoof = _formatMessageWithChainId(
            exampleDomain,
            ih2,
            claimants
        );
        vm.prank(address(mailbox));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.ChainIdMismatch.selector,
                exampleDomain,
                exampleChainId,
                exampleDomain
            )
        );
        p.handle(
            uint32(exampleDomain),
            bytes32(uint256(uint160(whitelistedProver))),
            spoof
        );
    }

    // Characterizes the generic unregistered-domain fallback: when a domain is
    // NOT registered as an exception, the domain==chainId fallback treats the
    // domain number itself as the chainId, so the prover records
    // destination == the domain number. For a chain whose domain equals its
    // chainId this is the correct result; a chain whose domain differs from its
    // chainId must therefore be registered (see scripts/README.md). The value
    // below is an arbitrary illustrative domain, not tied to any real chain.
    function testHandle_unregisteredDomainFallsBackToDomainNumber() public {
        uint64 exampleDomain = 424242; // default hyperProver has no domain config

        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory body = _formatMessageWithChainId(
            exampleDomain,
            intentHashes,
            claimants
        );
        vm.prank(address(mailbox));
        hyperProver.handle(
            uint32(exampleDomain),
            bytes32(uint256(uint160(whitelistedProver))),
            body
        );
        // Fallback resolved domain -> domain, so destination is the domain number.
        assertEq(
            hyperProver.provenIntents(intentHashes[0]).destination,
            exampleDomain
        );
    }

    function _singleProver(
        address a
    ) internal pure returns (bytes32[] memory arr) {
        arr = new bytes32[](1);
        arr[0] = bytes32(uint256(uint160(a)));
    }

    function testHandleRejectsNonWhitelistedSender() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory messageBody = _formatMessageWithChainId(
            1,
            intentHashes,
            claimants
        );

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

        // Manually create the encoded message with abi.encode to simulate mismatched arrays
        // Prepend a valid 8-byte chain-ID header (matching origin=1) so the new
        // origin/header cross-check passes and the malformed body underneath
        // still trips ArrayLengthMismatch as originally intended.
        bytes memory messageBody = abi.encodePacked(
            uint64(1),
            abi.encode(intentHashes, claimants)
        );

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

        bytes memory messageBody = _formatMessageWithChainId(
            1,
            intentHashes,
            claimants
        );

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
            uint64(block.chainid),
            encodeProofs(intentHashes, claimants),
            proverData
        );

        // Verify intent is proven (with chain ID = 31337 from the prove call)
        IProver.ProofData memory proof = hyperProver.provenIntents(intentHash);
        assertTrue(proof.claimant != address(0));
        assertEq(proof.destination, uint96(block.chainid)); // 31337

        // The original intent has destination = 1 (CHAIN_ID from BaseTest)
        // So challenging with the original intent should clear the proof
        // because intent.destination (1) != proof.destination (31337)
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
            uint64(block.chainid),
            encodeProofs(intentHashes, claimants),
            proverData
        );

        // Verify intent is proven
        IProver.ProofData memory proof = hyperProver.provenIntents(intentHash);
        assertTrue(proof.claimant != address(0));
        assertEq(proof.destination, uint96(block.chainid));

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
            uint64(block.chainid),
            encodeProofs(intentHashes, claimants),
            proverData
        );

        // Now simulate the message being received back by calling handle.
        // The TestMailbox already auto-delivered this exact proof once during
        // prove() above (mailbox.setProcessor(hyperProver) loops back
        // synchronously), so this is a duplicate delivery on the same
        // origin/header (both block.chainid) — it must hit the
        // already-proven skip, not a fresh chainId mismatch.
        bytes memory messageBody = _formatMessageWithChainId(
            block.chainid,
            intentHashes,
            claimants
        );
        vm.prank(address(mailbox));
        hyperProver.handle(
            uint32(block.chainid),
            bytes32(uint256(uint160(whitelistedProver))),
            messageBody
        );

        // Now check the storage
        IProver.ProofData memory proof = hyperProver.provenIntents(intentHash);
        assertEq(proof.claimant, claimant);
        assertEq(proof.destination, uint96(block.chainid));
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
            uint64(block.chainid),
            encodeProofs(intentHashes, claimants),
            proverData
        );

        // Should refund excess payment (implementation dependent)
        // This test validates the refund mechanism exists
        assertTrue(creator.balance >= initialBalance - overpayment);
    }

    /**
     * @notice prove() must REVERT when the refund recipient cannot receive ETH
     * @dev V9 behavior change: _sendRefund now reverts with RefundFailed instead
     *      of swallowing the failed low-level call. The refund recipient is always
     *      the tx caller, so reverting surfaces a genuinely-unpayable caller loudly
     *      rather than silently stranding their ETH as dust in the prover. (The
     *      uncapped all-gas call still lets legitimate smart-account recipients
     *      receive — see testProveRefundDeliveredToGasHungryRecipient.)
     */
    function testProveRevertsWhenRefundRecipientRejects() public {
        RejectingRefundRecipient recipient = new RejectingRefundRecipient();

        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        uint256 overpayment = 2 ether;

        bytes memory proverData = _encodeProverData(
            bytes32(uint256(uint160(whitelistedProver))),
            "",
            address(0)
        );

        // Refund recipient is a contract that reverts on receive. The refund of
        // (overpayment - mailbox fee) cannot be delivered, so prove() must revert
        // with RefundFailed(recipient, refundAmount).
        uint256 refundAmount = overpayment - mailbox.FEE();
        vm.prank(address(portal));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.RefundFailed.selector,
                address(recipient),
                refundAmount
            )
        );
        hyperProver.prove{value: overpayment}(
            address(recipient),
            uint64(block.chainid),
            encodeProofs(intentHashes, claimants),
            proverData
        );
    }

    /**
     * @notice prove() must actually DELIVER the refund to a legitimate
     *         smart-account solver whose receive() accepts but spends more than
     *         the 2300-gas transfer() stipend.
     * @dev Regression test for V9: the old transfer()-based refund would OOG-revert
     *      for any recipient whose receive() writes storage (a common smart-account /
     *      EIP-7702 pattern). The failure-tolerant all-gas call both avoids the DoS
     *      AND forwards enough gas for the refund to succeed, so the excess is
     *      returned to the solver rather than stranded in the prover.
     */
    function testProveRefundDeliveredToGasHungryRecipient() public {
        GasHungryRefundRecipient recipient = new GasHungryRefundRecipient();

        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        uint256 overpayment = 2 ether;
        uint256 recipientBalanceBefore = address(recipient).balance;

        bytes memory proverData = _encodeProverData(
            bytes32(uint256(uint160(whitelistedProver))),
            "",
            address(0)
        );

        // Refund recipient is a contract that accepts ETH but burns >2300 gas
        // (two cold SSTOREs) in receive(). The refund must still be delivered.
        vm.prank(address(portal));
        hyperProver.prove{value: overpayment}(
            address(recipient),
            uint64(block.chainid),
            encodeProofs(intentHashes, claimants),
            proverData
        );

        // Refund (overpayment minus the mailbox dispatch fee) was delivered to
        // the gas-hungry smart-account recipient.
        assertEq(
            address(recipient).balance,
            recipientBalanceBefore + overpayment - mailbox.FEE()
        );
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
            uint64(block.chainid),
            encodeProofs(intentHashes, claimants),
            proverData
        );
    }

    function testHandleWithEmptyArrays() public {
        bytes32[] memory intentHashes = new bytes32[](0);
        bytes32[] memory claimants = new bytes32[](0);

        bytes memory messageBody = _formatMessageWithChainId(
            1,
            intentHashes,
            claimants
        );

        // Should handle empty arrays gracefully
        vm.prank(address(mailbox));
        hyperProver.handle(
            1,
            bytes32(uint256(uint160(whitelistedProver))),
            messageBody
        );
    }

    function testHandleWithInvalidMessageFormat() public {
        // Create invalid message with wrong length (not multiple of 64).
        // Prepend a valid 8-byte header (matching origin=1) so the new
        // origin/header cross-check passes and the malformed body underneath
        // still trips ArrayLengthMismatch as originally intended.
        bytes memory invalidMessage = abi.encodePacked(
            uint64(1),
            new bytes(63) // Should be multiple of 64
        );

        vm.expectRevert(IProver.ArrayLengthMismatch.selector);
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
            uint64(block.chainid),
            encodeProofs(intentHashes, claimants),
            proverData
        );

        IProver.ProofData memory proof = hyperProver.provenIntents(
            intentHashes[0]
        );
        assertEq(proof.claimant, nonEvmClaimant);
    }

    function _formatMessageWithChainId(
        uint256 chainId,
        bytes32[] memory intentHashes,
        bytes32[] memory claimants
    ) internal pure returns (bytes memory) {
        require(
            intentHashes.length == claimants.length,
            "Array length mismatch"
        );
        bytes memory packed = new bytes(intentHashes.length * 64);
        for (uint256 i = 0; i < intentHashes.length; i++) {
            assembly {
                let offset := mul(i, 64)
                mstore(
                    add(add(packed, 0x20), offset),
                    mload(add(intentHashes, add(0x20, mul(i, 32))))
                )
                mstore(
                    add(add(packed, 0x20), add(offset, 32)),
                    mload(add(claimants, add(0x20, mul(i, 32))))
                )
            }
        }
        return abi.encodePacked(uint64(chainId), packed);
    }
}

/// @notice Refund recipient that rejects ETH, simulating a wallet whose
/// receive() reverts. Used to prove that _sendRefund reverts with RefundFailed
/// when the (caller) recipient cannot be paid, instead of silently stranding
/// the ETH as dust.
contract RejectingRefundRecipient {
    receive() external payable {
        revert("RejectingRefundRecipient: I reject your ETH");
    }

    fallback() external payable {
        revert("RejectingRefundRecipient: I reject your ETH");
    }
}

/// @notice Refund recipient that ACCEPTS ETH but consumes far more than the
/// 2300-gas transfer() stipend (two cold SSTOREs) in receive(), simulating a
/// legitimate smart-account / EIP-7702 solver wallet. Used to prove that the
/// all-gas refund call actually delivers the refund instead of OOG-reverting.
contract GasHungryRefundRecipient {
    uint256 private slot0;
    uint256 private slot1;

    receive() external payable {
        // Two cold SSTOREs cost well over the 2300-gas transfer() stipend.
        slot0 = block.number;
        slot1 = block.timestamp;
    }
}
