// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {PolymerProver} from "../../contracts/prover/PolymerProver.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {TestCrossL2ProverV2} from "../../contracts/test/TestCrossL2ProverV2.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../../contracts/types/Intent.sol";

contract PolymerProverTest is BaseTest {
    PolymerProver internal polymerProver;
    TestCrossL2ProverV2 internal crossL2ProverV2;
    address internal destinationProver;

    uint32 constant OPTIMISM_CHAIN_ID = 10;
    uint32 constant ARBITRUM_CHAIN_ID = 42161;

    bytes32 constant PROOF_SELECTOR =
        keccak256("IntentFulfilledFromSource(bytes32,bytes32,uint64)");

    bytes internal emptyTopics =
        hex"0000000000000000000000000000000000000000000000000000000000000000";
    bytes internal emptyData = hex"";

    /**
     * @notice Helper function to encode proofs from separate arrays
     * @param intentHashes Array of intent hashes
     * @param claimants Array of claimant addresses (as bytes32)
     * @return encodedProofs Encoded (intentHash, claimant) pairs as bytes
     */
    function encodeProofs(
        bytes32[] memory intentHashes,
        bytes32[] memory claimants
    ) internal pure returns (bytes memory encodedProofs) {
        require(
            intentHashes.length == claimants.length,
            "Array length mismatch"
        );

        encodedProofs = new bytes(intentHashes.length * 64);
        for (uint256 i = 0; i < intentHashes.length; i++) {
            assembly {
                let offset := mul(i, 64)
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

        crossL2ProverV2 = new TestCrossL2ProverV2(
            OPTIMISM_CHAIN_ID,
            address(portal),
            emptyTopics,
            emptyData
        );

        // Create mock destination prover address
        destinationProver = makeAddr("destinationProver");

        // Deploy PolymerProver with owner and portal
        polymerProver = new PolymerProver(
            address(this), // owner
            address(portal)
        );

        // Initialize with CrossL2ProverV2 and whitelist
        uint64[] memory chainIds = new uint64[](2);
        bytes32[] memory provers = new bytes32[](2);
        chainIds[0] = OPTIMISM_CHAIN_ID;
        chainIds[1] = ARBITRUM_CHAIN_ID;
        provers[0] = bytes32(uint256(uint160(destinationProver)));
        provers[1] = bytes32(uint256(uint160(destinationProver)));

        polymerProver.initialize(address(crossL2ProverV2), chainIds, provers);

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
            intentHash,
            claimants[0],
            uint64(block.chainid)
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

    function testValidateSingleProof() public {
        bytes32 intentHash = _hashIntent(intent);

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            intentHash, // intent hash
            bytes32(uint256(uint160(claimant))), // claimant address
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            emptyData
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

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            intentHash, // intent hash
            bytes32(uint256(uint160(claimant))), // claimant address
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            emptyData
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        polymerProver.validate(proof);

        _expectEmit();
        emit IProver.IntentAlreadyProven(intentHash);

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
                PROOF_SELECTOR, // event signature
                intentHashes[i], // intent hash
                bytes32(uint256(uint160(claimants[i]))), // claimant address
                bytes32(uint256(uint64(block.chainid))) // source chain ID
            );

            crossL2ProverV2.setAll(
                chainIds[i],
                destinationProver,
                topics,
                emptyData
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

    function testValidateRevertsOnInvalidEmittingContract() public {
        bytes32 intentHash = _hashIntent(intent);

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            intentHash, // intent hash
            bytes32(uint256(uint160(claimant))), // claimant address
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            creator, // wrong contract
            topics,
            emptyData
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
        bytes32 intentHash = _hashIntent(intent);

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR,
            intentHash
            // missing claimant topic
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
        bytes32 intentHash = _hashIntent(intent);
        bytes32 wrongSignature = keccak256(
            "WrongSignature(bytes32,bytes32,uint64)"
        );

        bytes memory topics = abi.encodePacked(
            wrongSignature, // wrong event signature
            intentHash, // intent hash
            bytes32(uint256(uint160(claimant))), // claimant address
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            emptyData
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.expectRevert(PolymerProver.InvalidEventSignature.selector);
        polymerProver.validate(proof);
    }

    function testChallengeIntentProofWithWrongDestination() public {
        bytes32 intentHash = _hashIntent(intent);

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            intentHash, // intent hash
            bytes32(uint256(uint160(claimant))), // claimant address
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            emptyData
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

        bytes memory topics = abi.encodePacked(
            PROOF_SELECTOR, // event signature
            intentHash, // intent hash
            bytes32(uint256(uint160(claimant))), // claimant address
            bytes32(uint256(uint64(block.chainid))) // source chain ID
        );

        crossL2ProverV2.setAll(
            OPTIMISM_CHAIN_ID,
            destinationProver,
            topics,
            emptyData
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

    function testInitializeCanOnlyBeCalledOnce() public {
        uint64[] memory chainIds = new uint64[](1);
        bytes32[] memory provers = new bytes32[](1);
        chainIds[0] = OPTIMISM_CHAIN_ID;
        provers[0] = bytes32(uint256(uint160(destinationProver)));

        // Should revert since initialize was already called in setUp
        vm.expectRevert();
        polymerProver.initialize(address(crossL2ProverV2), chainIds, provers);
    }

    function testInitializeOnlyCallableByOwner() public {
        PolymerProver newProver = new PolymerProver(
            address(this), // owner
            address(portal)
        );

        uint64[] memory chainIds = new uint64[](1);
        bytes32[] memory provers = new bytes32[](1);
        chainIds[0] = OPTIMISM_CHAIN_ID;
        provers[0] = bytes32(uint256(uint160(destinationProver)));

        // Should revert when called by non-owner
        vm.prank(creator);
        vm.expectRevert();
        newProver.initialize(address(crossL2ProverV2), chainIds, provers);
    }
}
