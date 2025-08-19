// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../BaseTest.sol";
import {PolymerProver} from "../../contracts/prover/PolymerProver.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {TestCrossL2ProverV2} from "../../contracts/test/TestCrossL2ProverV2.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../../contracts/types/Intent.sol";

contract PolymerProverTest is BaseTest {
    PolymerProver internal polymerProver;
    TestCrossL2ProverV2 internal crossL2ProverV2;

    uint32 constant OPTIMISM_CHAIN_ID = 10;
    uint32 constant ARBITRUM_CHAIN_ID = 42161;

    bytes32 constant PROOF_SELECTOR = keccak256("Fulfillment(bytes32,uint256,address)");

    bytes internal emptyTopics = hex"0000000000000000000000000000000000000000000000000000000000000000";
    bytes internal emptyData = hex"";


    function setUp() public override {
        super.setUp();

        crossL2ProverV2 = new TestCrossL2ProverV2(
            OPTIMISM_CHAIN_ID,
            address(inbox), // Inbox contract that emits Fulfillment events
            emptyTopics,
            emptyData
        );

        // Deploy PolymerProver with just owner (v1.5 pattern)
        polymerProver = new PolymerProver(
            address(this) // owner
        );

        // Initialize with CrossL2ProverV2 and whitelist the Inbox contracts
        uint64[] memory chainIds = new uint64[](2);
        bytes32[] memory inboxes = new bytes32[](2);
        chainIds[0] = OPTIMISM_CHAIN_ID;
        chainIds[1] = ARBITRUM_CHAIN_ID;
        // Whitelist the Inbox contract address as the emitter
        inboxes[0] = bytes32(uint256(uint160(address(inbox))));
        inboxes[1] = bytes32(uint256(uint160(address(inbox))));

        polymerProver.initialize(
            address(crossL2ProverV2),
            chainIds,
            inboxes
        );

        _mintAndApprove(creator, MINT_AMOUNT);
        _fundUserNative(creator, 10 ether);
    }

    function testInitializesCorrectly() public view {
        assertTrue(address(polymerProver) != address(0));
        assertEq(uint256(polymerProver.getProofType()), uint256(IProver.ProofType.Polymer));
        assertEq(address(polymerProver.CROSS_L2_PROVER_V2()), address(crossL2ProverV2));
    }

    function testValidateSingleProof() public {
        bytes32 intentHash = _hashIntent(intent);

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,                                      // event signature
            intentHash,                                          // intent hash
            bytes32(uint256(uint64(block.chainid))),             // source chain ID
            bytes32(uint256(uint160(claimant)))                  // claimant address
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            address(inbox),
            topics,
            emptyData
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        _expectEmit();
        emit IProver.IntentProven(intentHash, claimant);

        polymerProver.validate(proof);

        address provenClaimant = polymerProver.provenIntents(intentHash);
        assertEq(provenClaimant, claimant);
    }

    function testValidateEmitsAlreadyProvenForDuplicate() public {
        bytes32 intentHash = _hashIntent(intent);

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,                                      // event signature
            intentHash,                                          // intent hash
            bytes32(uint256(uint64(block.chainid))),             // source chain ID
            bytes32(uint256(uint160(claimant)))                  // claimant address
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            address(inbox),
            topics,
            emptyData
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        polymerProver.validate(proof);

        _expectEmit();
        emit PolymerProver.IntentAlreadyProven(intentHash);

        polymerProver.validate(proof);
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
            bytes memory topics = abi.encodePacked(
                PROOF_SELECTOR,                                      // event signature
                intentHashes[i],                                     // intent hash
                bytes32(uint256(uint64(block.chainid))),             // source chain ID
                bytes32(uint256(uint160(claimants[i])))              // claimant address
            );

            crossL2ProverV2.setAll(
                chainIds[i],
                address(inbox),
                topics,
                emptyData
            );

            proofs[i] = abi.encodePacked(uint256(i + 1));
        }

        polymerProver.validateBatch(proofs);

        for (uint256 i = 0; i < 3; i++) {
            address provenClaimant = polymerProver.provenIntents(intentHashes[i]);
            assertEq(provenClaimant, claimants[i]);
        }
    }

    function testValidateRevertsOnInvalidEmittingContract() public {
        bytes32 intentHash = _hashIntent(intent);

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,                                      // event signature
            intentHash,                                          // intent hash
            bytes32(uint256(uint64(block.chainid))),             // source chain ID
            bytes32(uint256(uint160(claimant)))                  // claimant address
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            creator, // wrong contract
            topics,
            emptyData
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.expectRevert(abi.encodeWithSelector(PolymerProver.InvalidEmittingContract.selector, creator));
        polymerProver.validate(proof);
    }


    function testValidateRevertsOnInvalidTopicsLength() public {
        bytes32 intentHash = _hashIntent(intent);

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,
            intentHash
            // missing claimant topic
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            address(inbox),
            topics,
            emptyData
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.expectRevert(PolymerProver.InvalidTopicsLength.selector);
        polymerProver.validate(proof);
    }

    function testValidateRevertsOnInvalidEventSignature() public {
        bytes32 intentHash = _hashIntent(intent);
        bytes32 wrongSignature = keccak256("WrongSignature(bytes32,bytes32,uint64)");

        bytes memory topics = abi.encodePacked(
            wrongSignature,                                      // wrong event signature
            intentHash,                                          // intent hash
            bytes32(uint256(uint160(claimant))),                 // claimant address
            bytes32(uint256(uint64(block.chainid)))              // source chain ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            address(inbox),
            topics,
            emptyData
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.expectRevert(PolymerProver.InvalidEventSignature.selector);
        polymerProver.validate(proof);
    }

    function testGetIntentClaimantFunction() public {
        bytes32 intentHash = _hashIntent(intent);

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,                                      // event signature
            intentHash,                                          // intent hash
            bytes32(uint256(uint64(block.chainid))),             // source chain ID
            bytes32(uint256(uint160(claimant)))                  // claimant address
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            address(inbox),
            topics,
            emptyData
        );

        bytes memory proof = abi.encodePacked(uint256(1));
        polymerProver.validate(proof);

        // Test the getIntentClaimant interface function
        address retrievedClaimant = polymerProver.getIntentClaimant(intentHash);
        assertEq(retrievedClaimant, claimant);
    }

    function testInitializeCanOnlyBeCalledOnce() public {
        uint64[] memory chainIds = new uint64[](1);
        bytes32[] memory provers = new bytes32[](1);
        chainIds[0] = OPTIMISM_CHAIN_ID;
        provers[0] = bytes32(uint256(uint160(address(inbox))));

        // Should revert since initialize was already called in setUp
        vm.expectRevert();
        polymerProver.initialize(
            address(crossL2ProverV2),
            chainIds,
            provers
        );
    }

    function testInitializeOnlyCallableByOwner() public {
        PolymerProver newProver = new PolymerProver(
            address(this) // owner
        );

        uint64[] memory chainIds = new uint64[](1);
        bytes32[] memory provers = new bytes32[](1);
        chainIds[0] = OPTIMISM_CHAIN_ID;
        provers[0] = bytes32(uint256(uint160(address(inbox))));

        // Should revert when called by non-owner
        vm.prank(creator);
        vm.expectRevert();
        newProver.initialize(
            address(crossL2ProverV2),
            chainIds,
            provers
        );
    }
}
