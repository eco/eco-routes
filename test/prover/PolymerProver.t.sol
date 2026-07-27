// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {PolymerProver} from "../../contracts/prover/PolymerProver.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {TestCrossL2ProverV2} from "../../contracts/test/TestCrossL2ProverV2.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../../contracts/types/Intent.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PolymerProverTest is BaseTest {
    PolymerProver internal polymerProver;
    TestCrossL2ProverV2 internal crossL2ProverV2;
    address internal destinationProver;

    uint32 constant OPTIMISM_CHAIN_ID = 10;
    uint32 constant ARBITRUM_CHAIN_ID = 42161;

    bytes32 constant PROOF_SELECTOR =
        keccak256("IntentFulfilledFromSource(uint64,bytes)");

    bytes internal emptyTopics =
        hex"0000000000000000000000000000000000000000000000000000000000000000";
    bytes internal emptyData = hex"";

    /**
     * @notice Helper function to encode proofs from separate arrays with 8-byte chain ID prefix
     * @param intentHashes Array of intent hashes
     * @param claimants Array of claimant addresses (as bytes32)
     * @return encodedProofs Encoded 8-byte chain ID + (intentHash, claimant) pairs as bytes
     */
    function encodeProofs(
        bytes32[] memory intentHashes,
        bytes32[] memory claimants
    ) internal view returns (bytes memory encodedProofs) {
        return
            encodeProofsWithChainId(
                intentHashes,
                claimants,
                uint64(block.chainid)
            );
    }

    /**
     * @notice Helper function to encode proofs with specific chain ID prefix
     * @param intentHashes Array of intent hashes
     * @param claimants Array of claimant addresses (as bytes32)
     * @param chainId Chain ID to encode in the prefix
     * @return encodedProofs Encoded 8-byte chain ID + (intentHash, claimant) pairs as bytes
     */
    function encodeProofsWithChainId(
        bytes32[] memory intentHashes,
        bytes32[] memory claimants,
        uint64 chainId
    ) internal pure returns (bytes memory encodedProofs) {
        require(
            intentHashes.length == claimants.length,
            "Array length mismatch"
        );

        encodedProofs = new bytes(8 + intentHashes.length * 64);

        // Add 8-byte chain ID prefix
        assembly {
            mstore(add(encodedProofs, 0x20), shl(192, chainId))
        }

        for (uint256 i = 0; i < intentHashes.length; i++) {
            assembly {
                let offset := add(8, mul(i, 64))
                // Store hash in first 32 bytes of each pair (after 8-byte prefix)
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

        crossL2ProverV2 = new TestCrossL2ProverV2(
            OPTIMISM_CHAIN_ID,
            address(portal),
            emptyTopics,
            emptyData
        );

        // Create mock destination prover address
        destinationProver = makeAddr("destinationProver");

        // Create whitelist array for constructor (address only)
        bytes32[] memory provers = new bytes32[](1);
        provers[0] = bytes32(uint256(uint160(destinationProver)));

        // Deploy PolymerProver with portal, crossL2ProverV2, maxLogDataSize, and whitelist
        polymerProver = new PolymerProver(
            address(portal),
            address(crossL2ProverV2),
            32 * 1024, // maxLogDataSize
            provers
        );

        _mintAndApprove(creator, MINT_AMOUNT);
        _fundUserNative(creator, 10 ether);
    }

    function testInitializesCorrectly() public view {
        assertTrue(address(polymerProver) != address(0));
        assertEq(polymerProver.getProofType(), "Polymer");
        assertEq(
            address(polymerProver.CROSS_L2_PROVER_V2()),
            address(crossL2ProverV2)
        );
        assertEq(polymerProver.PORTAL(), address(portal));

        // Test whitelist functionality
        assertTrue(
            polymerProver.isWhitelisted(
                bytes32(uint256(uint160(destinationProver)))
            )
        );
        assertEq(polymerProver.getWhitelistSize(), 1);
    }

    function testImplementsIProverInterface() public view {
        assertTrue(polymerProver.supportsInterface(type(IProver).interfaceId));
    }

    function testSupportsInterface() public view {
        assertTrue(polymerProver.supportsInterface(type(IProver).interfaceId));
        assertTrue(polymerProver.supportsInterface(0x01ffc9a7)); // ERC165
    }

    function testProveOnlyCallableByPortal() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);

        // Should revert when called by non-portal
        vm.expectRevert(PolymerProver.OnlyPortal.selector);
        polymerProver.prove(
            creator,
            uint64(block.chainid),
            encodedProofs,
            hex""
        );
    }

    function testProveEmitsEvents() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        bytes32 intentHash = _hashIntent(intent);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);

        _expectEmit();
        emit PolymerProver.IntentFulfilledFromSource(
            uint64(block.chainid),
            encodedProofs
        );

        vm.prank(address(portal));
        polymerProver.prove(
            creator,
            uint64(block.chainid),
            encodedProofs,
            hex""
        );
    }

    function testProveHandlesEmptyProofs() public {
        vm.prank(address(portal));
        polymerProver.prove(creator, uint64(block.chainid), hex"", hex"");
    }

    function testProveEmitsMultipleIntents() public {
        bytes32[] memory intentHashes = new bytes32[](3);
        bytes32[] memory claimants = new bytes32[](3);

        for (uint256 i = 0; i < 3; i++) {
            Intent memory testIntent = intent;
            testIntent.route.salt = keccak256(abi.encodePacked(salt, i));
            intentHashes[i] = _hashIntent(testIntent);
            claimants[i] = bytes32(uint256(uint160(claimant)));
        }

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);

        _expectEmit();
        emit PolymerProver.IntentFulfilledFromSource(
            uint64(block.chainid),
            encodedProofs
        );

        vm.prank(address(portal));
        polymerProver.prove(
            creator,
            uint64(block.chainid),
            encodedProofs,
            hex""
        );
    }

    /**
     * @notice prove() must refund forwarded ETH to the caller rather than trap it
     * @dev Regression test for V9: Polymer proving requires no bridge fee, but
     *      Inbox.prove forwards the Portal's entire balance (forced dust or
     *      overpayment). Previously prove() was payable and only emitted an event,
     *      permanently trapping any msg.value in the prover. It must now refund
     *      the forwarded value to the sender.
     */
    function testProveRefundsForwardedValueToSender() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);

        uint256 forwarded = 1 ether;
        vm.deal(address(portal), forwarded);
        uint256 creatorBalanceBefore = creator.balance;

        vm.prank(address(portal));
        polymerProver.prove{value: forwarded}(
            creator,
            uint64(block.chainid),
            encodedProofs,
            hex""
        );

        // Forwarded ETH is refunded to the sender, nothing trapped in the prover
        assertEq(creator.balance, creatorBalanceBefore + forwarded);
        assertEq(address(polymerProver).balance, 0);
    }

    /**
     * @notice prove() must not revert when the refund recipient rejects ETH
     * @dev Regression test for V9: the refund uses a failure-tolerant all-gas call
     *      so a recipient whose receive()/fallback() reverts cannot DoS
     *      prove()/fulfillAndProve(). Polymer charges no bridge fee, so when the
     *      refund cannot be delivered the entire forwarded amount is retained as
     *      dust in the prover (there is no sweep path; the loss is self-inflicted
     *      since the recipient is the caller). Exercises the dust-retention branch.
     */
    function testProveRefundRetainedWhenRecipientRejects() public {
        RejectingRefundRecipient rejecting = new RejectingRefundRecipient();

        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory encodedProofs = encodeProofs(intentHashes, claimants);

        uint256 forwarded = 1 ether;
        vm.deal(address(portal), forwarded);

        // Refund recipient reverts on receive; with the old transfer()-based refund
        // this would revert. It must now succeed, retaining the value as dust.
        vm.prank(address(portal));
        polymerProver.prove{value: forwarded}(
            address(rejecting),
            uint64(block.chainid),
            encodedProofs,
            hex""
        );

        // Refund could not be delivered, so the full forwarded amount (no fee on
        // Polymer) is retained by the prover; nothing reaches the recipient.
        assertEq(address(rejecting).balance, 0);
        assertEq(address(polymerProver).balance, forwarded);
    }

    /**
     * @notice The nonReentrant guard on Inbox.prove blocks a refund recipient
     *         from reentering prove().
     * @dev Regression test for V9: Inbox.prove forwards the Portal's full balance
     *      into the prover, whose failure-tolerant refund makes an all-gas call
     *      back to msg.sender. Polymer has no fee, so the whole forwarded amount is
     *      refunded to the caller. A malicious caller reenters Inbox.prove from its
     *      receive(); the guard must revert that reentrant call
     *      (ReentrancyGuardReentrantCall). Because the refund is failure-tolerant,
     *      the reentrant revert is swallowed and the OUTER prove() still succeeds.
     */
    function testInboxProveReentrancyIsBlocked() public {
        // Build a fulfillable intent on this chain with no route tokens/calls so
        // fulfillment needs no token setup. Inbox computes the hash with its own
        // CHAIN_ID (== block.chainid), so destination must match.
        Intent memory localIntent = intent;
        localIntent.destination = uint64(block.chainid);
        localIntent.route.tokens = new TokenAmount[](0);
        localIntent.route.calls = new Call[](0);

        bytes32 intentHash = _hashIntent(localIntent);
        bytes32 rewardHash = keccak256(abi.encode(localIntent.reward));

        // A solver fulfills the intent so claimants[intentHash] is set.
        address solver = makeAddr("polySolver");
        vm.prank(solver);
        portal.fulfill(
            intentHash,
            localIntent.route,
            rewardHash,
            bytes32(uint256(uint160(claimant)))
        );

        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = intentHash;

        // The malicious caller reenters Inbox.prove from its receive().
        ReentrantProveCaller attacker = new ReentrantProveCaller(
            address(portal),
            address(polymerProver),
            uint64(block.chainid),
            intentHashes
        );

        uint256 amount = 1 ether;
        vm.deal(address(attacker), amount);

        // Outer prove() must succeed despite the blocked reentrant attempt.
        attacker.attack();

        // The reentrant call was attempted and reverted with the guard error.
        assertTrue(attacker.reentrancyAttempted(), "reentry not attempted");
        assertTrue(attacker.reentrantReverted(), "guard did not block reentry");
        assertEq(
            bytes4(attacker.reentrantRevertData()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector
        );

        // Portal drained its balance before the callback; the refund was
        // delivered out to the caller, leaving nothing trapped in prover/portal.
        assertEq(address(portal).balance, 0);
        assertEq(address(polymerProver).balance, 0);
        assertEq(address(attacker).balance, amount);
    }

    function testValidateSingleProof() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        _expectEmit();
        emit IProver.IntentProven(intentHash, claimant, OPTIMISM_CHAIN_ID);

        polymerProver.validate(proof);

        IProver.ProofData memory proofData = polymerProver.provenIntents(
            intentHash
        );
        assertEq(proofData.claimant, claimant);
        assertEq(proofData.destination, OPTIMISM_CHAIN_ID);
    }

    function testValidateEmitsAlreadyProvenForDuplicate() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        polymerProver.validate(proof);

        _expectEmit();
        emit IProver.IntentAlreadyProven(intentHash);

        polymerProver.validate(proof);
    }

    function testValidateMultipleIntentsInSingleEvent() public {
        bytes32[] memory intentHashes = new bytes32[](3);
        bytes32[] memory claimants = new bytes32[](3);

        for (uint256 i = 0; i < 3; i++) {
            Intent memory testIntent = intent;
            testIntent.route.salt = keccak256(abi.encodePacked(salt, i));
            intentHashes[i] = _hashIntent(testIntent);
            claimants[i] = bytes32(uint256(uint160(claimant)));
        }

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,
            bytes32(uint256(uint64(block.chainid)))
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        _expectEmit();
        emit IProver.IntentProven(intentHashes[0], claimant, OPTIMISM_CHAIN_ID);
        _expectEmit();
        emit IProver.IntentProven(intentHashes[1], claimant, OPTIMISM_CHAIN_ID);
        _expectEmit();
        emit IProver.IntentProven(intentHashes[2], claimant, OPTIMISM_CHAIN_ID);

        polymerProver.validate(proof);

        for (uint256 i = 0; i < 3; i++) {
            IProver.ProofData memory proofData = polymerProver.provenIntents(
                intentHashes[i]
            );
            assertEq(proofData.claimant, claimant);
            assertEq(proofData.destination, OPTIMISM_CHAIN_ID);
        }
    }

    function testValidateBatch() public {
        bytes32[] memory intentHashes = new bytes32[](3);
        address[] memory claimants = new address[](3);

        for (uint256 i = 0; i < 3; i++) {
            Intent memory testIntent = intent;
            testIntent.route.salt = keccak256(abi.encodePacked(salt, i));
            intentHashes[i] = _hashIntent(testIntent);
            claimants[i] = claimant;
        }

        bytes[] memory proofs = new bytes[](3);
        uint32[] memory chainIds = new uint32[](3);
        chainIds[0] = OPTIMISM_CHAIN_ID;
        chainIds[1] = ARBITRUM_CHAIN_ID;
        chainIds[2] = OPTIMISM_CHAIN_ID;

        for (uint256 i = 0; i < 3; i++) {
            bytes32[] memory singleIntentHash = new bytes32[](1);
            bytes32[] memory singleClaimant = new bytes32[](1);
            singleIntentHash[0] = intentHashes[i];
            singleClaimant[0] = bytes32(uint256(uint160(claimants[i])));

            bytes memory topics = abi.encodePacked(
                PROOF_SELECTOR, // event signature
                bytes32(uint256(uint64(block.chainid))) // source chain ID
            );

            bytes memory data = encodeProofsWithChainId(
                singleIntentHash,
                singleClaimant,
                chainIds[i]
            );

            crossL2ProverV2.setAll(
                chainIds[i],
                destinationProver,
                topics,
                data
            );

            proofs[i] = abi.encodePacked(uint256(i + 1));
        }

        polymerProver.validateBatch(proofs);

        for (uint256 i = 0; i < 3; i++) {
            IProver.ProofData memory proofData = polymerProver.provenIntents(
                intentHashes[i]
            );
            assertEq(proofData.claimant, claimants[i]);
            assertEq(proofData.destination, chainIds[i]);
        }
    }

    function testValidateBatchWithDuplicate() public {
        bytes32[] memory intentHashes = new bytes32[](2);
        address[] memory claimants = new address[](2);

        for (uint256 i = 0; i < 2; i++) {
            Intent memory testIntent = intent;
            testIntent.route.salt = keccak256(abi.encodePacked(salt, i));
            intentHashes[i] = _hashIntent(testIntent);
            claimants[i] = claimant;
        }

        bytes[] memory proofs = new bytes[](3);
        uint32[] memory chainIds = new uint32[](3);
        chainIds[0] = OPTIMISM_CHAIN_ID;
        chainIds[1] = ARBITRUM_CHAIN_ID;
        chainIds[2] = OPTIMISM_CHAIN_ID;

        for (uint256 i = 0; i < 2; i++) {
            bytes32[] memory singleIntentHash = new bytes32[](1);
            bytes32[] memory singleClaimant = new bytes32[](1);
            singleIntentHash[0] = intentHashes[i];
            singleClaimant[0] = bytes32(uint256(uint160(claimants[i])));

            bytes memory topics = abi.encodePacked(
                PROOF_SELECTOR, // event signature
                bytes32(uint256(uint64(block.chainid))) // source chain ID
            );

            bytes memory data = encodeProofsWithChainId(
                singleIntentHash,
                singleClaimant,
                chainIds[i]
            );

            crossL2ProverV2.setAll(
                chainIds[i],
                destinationProver,
                topics,
                data
            );

            proofs[i] = abi.encodePacked(uint256(i + 1));
        }

        bytes32[] memory duplicateIntentHash = new bytes32[](1);
        bytes32[] memory duplicateClaimant = new bytes32[](1);
        duplicateIntentHash[0] = intentHashes[0]; // Same as first
        duplicateClaimant[0] = bytes32(uint256(uint160(claimants[0])));

        bytes memory duplicateTopics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        bytes memory duplicateData = encodeProofsWithChainId(
            duplicateIntentHash,
            duplicateClaimant,
            chainIds[2]
        );

        crossL2ProverV2.setAll(
            chainIds[2],
            destinationProver,
            duplicateTopics,
            duplicateData
        );

        proofs[2] = abi.encodePacked(uint256(3));

        _expectEmit();
        emit IProver.IntentProven(intentHashes[0], claimant, OPTIMISM_CHAIN_ID);
        _expectEmit();
        emit IProver.IntentProven(intentHashes[1], claimant, ARBITRUM_CHAIN_ID);
        _expectEmit();
        emit IProver.IntentAlreadyProven(intentHashes[0]);

        polymerProver.validateBatch(proofs);

        for (uint256 i = 0; i < 2; i++) {
            IProver.ProofData memory proofData = polymerProver.provenIntents(
                intentHashes[i]
            );
            assertEq(proofData.claimant, claimants[i]);
            assertEq(proofData.destination, chainIds[i]);
        }
    }

    function testValidateRevertsOnInvalidEmittingContract() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            creator, // wrong contract
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.expectRevert(
            abi.encodeWithSelector(
                PolymerProver.InvalidEmittingContract.selector,
                creator
            )
        );
        polymerProver.validate(proof);
    }

    function testValidateRevertsOnInvalidTopicsLength() public {
        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR
            // missing source chain ID topic
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            emptyData
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.expectRevert(PolymerProver.InvalidTopicsLength.selector);
        polymerProver.validate(proof);
    }

    function testValidateRevertsOnInvalidEventSignature() public {
        bytes32 wrongSignature = keccak256("WrongSignature(uint64,bytes)");
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            wrongSignature, // wrong event signature
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.expectRevert(PolymerProver.InvalidEventSignature.selector);
        polymerProver.validate(proof);
    }

    function testChallengeIntentProofWithWrongDestination() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));
        polymerProver.validate(proof);

        IProver.ProofData memory proofData = polymerProver.provenIntents(
            intentHash
        );
        assertEq(proofData.claimant, claimant);
        assertEq(proofData.destination, OPTIMISM_CHAIN_ID);

        // Challenge with different destination (intent.destination = 1 from BaseTest, proof.destination = 10)
        polymerProver.challengeIntentProof(
            intent.destination, // 1
            keccak256(abi.encode(intent.route)),
            keccak256(abi.encode(intent.reward))
        );

        // Verify proof was cleared since destinations don't match
        proofData = polymerProver.provenIntents(intentHash);
        assertEq(proofData.claimant, address(0));
    }

    function testChallengeIntentProofWithCorrectDestination() public {
        Intent memory localIntent = intent;
        localIntent.destination = OPTIMISM_CHAIN_ID;
        bytes32 intentHash = _hashIntent(localIntent);
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = intentHash;
        claimants[0] = bytes32(uint256(uint160(claimant)));

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        bytes memory data = encodeProofsWithChainId(
            intentHashes,
            claimants,
            OPTIMISM_CHAIN_ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));
        polymerProver.validate(proof);

        // Challenge with correct destination should do nothing
        polymerProver.challengeIntentProof(
            localIntent.destination,
            keccak256(abi.encode(localIntent.route)),
            keccak256(abi.encode(localIntent.reward))
        );

        // Verify proof is still there
        IProver.ProofData memory proofData = polymerProver.provenIntents(
            intentHash
        );
        assertEq(proofData.claimant, claimant);
        assertEq(proofData.destination, OPTIMISM_CHAIN_ID);
    }

    function testWhitelistFunctionality() public {
        // Test that our destination prover is whitelisted (address only)
        assertTrue(
            polymerProver.isWhitelisted(
                bytes32(uint256(uint160(destinationProver)))
            )
        );

        // Test that a random address is not whitelisted
        address randomAddr = makeAddr("random");
        assertFalse(
            polymerProver.isWhitelisted(bytes32(uint256(uint160(randomAddr))))
        );

        // Test zero address is not whitelisted
        assertFalse(polymerProver.isWhitelisted(bytes32(0)));
    }

    function testConstructorWithEmptyWhitelist() public {
        bytes32[] memory emptyProvers = new bytes32[](0);

        PolymerProver newProver = new PolymerProver(
            address(portal),
            address(crossL2ProverV2),
            32 * 1024, // maxLogDataSize
            emptyProvers
        );

        assertEq(newProver.getWhitelistSize(), 0);
        assertFalse(
            newProver.isWhitelisted(
                bytes32(uint256(uint160(destinationProver)))
            )
        );
    }
}

/// @notice Minimal view of Inbox.prove used by the reentrancy attacker.
interface IInboxProve {
    function prove(
        address prover,
        uint64 sourceChainDomainID,
        bytes32[] memory intentHashes,
        bytes memory data
    ) external payable;
}

/// @notice Refund recipient that rejects ETH, forcing the dust-retention branch.
contract RejectingRefundRecipient {
    receive() external payable {
        revert("RejectingRefundRecipient: I reject your ETH");
    }

    fallback() external payable {
        revert("RejectingRefundRecipient: I reject your ETH");
    }
}

/// @notice Malicious refund recipient that attempts to reenter Inbox.prove from
/// its receive() when it is paid the forwarded refund. Records whether the
/// reentrant call reverted so the guard can be asserted from the test.
contract ReentrantProveCaller {
    IInboxProve public immutable portal;
    address public immutable prover;
    uint64 public immutable domain;
    bytes32[] public intentHashes;

    bool public reentrancyAttempted;
    bool public reentrantReverted;
    bytes public reentrantRevertData;

    constructor(
        address _portal,
        address _prover,
        uint64 _domain,
        bytes32[] memory _intentHashes
    ) {
        portal = IInboxProve(_portal);
        prover = _prover;
        domain = _domain;
        intentHashes = _intentHashes;
    }

    /// @notice Kick off the outer Inbox.prove call, forwarding our full balance.
    function attack() external {
        portal.prove{value: address(this).balance}(
            prover,
            domain,
            intentHashes,
            ""
        );
    }

    /// @notice Invoked when the prover refunds the forwarded value. Attempts to
    /// reenter Inbox.prove; the nonReentrant guard must revert this. We swallow
    /// the revert (low-level call) so the outer refund call still succeeds.
    receive() external payable {
        if (reentrancyAttempted) {
            return;
        }
        reentrancyAttempted = true;

        (bool ok, bytes memory ret) = address(portal).call(
            abi.encodeWithSelector(
                IInboxProve.prove.selector,
                prover,
                domain,
                intentHashes,
                bytes("")
            )
        );

        reentrantReverted = !ok;
        reentrantRevertData = ret;
    }
}
