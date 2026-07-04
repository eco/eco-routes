// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../BaseTest.sol";
import {PolymerPolicy} from "../../contracts/prover/PolymerPolicy.sol";
import {IPolicy} from "../../contracts/interfaces/IPolicy.sol";
import {TestCrossL2ProverV2} from "../../contracts/test/TestCrossL2ProverV2.sol";
import {Intent, Route, Reward, TokenAmount} from "../../contracts/types/Intent.sol";
import {Call} from "../../contracts/interfaces/IRuntime.sol";

contract PolymerProverTest is BaseTest {
    PolymerPolicy internal polymerProver;
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

        // Deploy PolymerPolicy with portal, crossL2ProverV2, maxLogDataSize, and whitelist
        polymerProver = new PolymerPolicy(
            address(portal),
            address(crossL2ProverV2),
            32 * 1024, // maxLogDataSize
            provers
        );

        _mintAndApprove(keeper, MINT_AMOUNT);
        _fundUserNative(keeper, 10 ether);
    }

    /// @dev Records each fulfillment into the prover (as the Portal) so `prove` can build its
    ///      message from the prover's own store — mirrors the destination fulfill happening first.
    function _record(
        bytes32[] memory intentHashes,
        bytes32[] memory claimants
    ) internal {
        for (uint256 i; i < intentHashes.length; ++i) {
            vm.prank(address(portal));
            polymerProver.recordFulfillment(
                intentHashes[i],
                uint64(block.chainid),
                claimants[i]
            );
        }
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
        assertTrue(polymerProver.supportsInterface(type(IPolicy).interfaceId));
    }

    function testSupportsInterface() public view {
        assertTrue(polymerProver.supportsInterface(type(IPolicy).interfaceId));
        assertTrue(polymerProver.supportsInterface(0x01ffc9a7)); // ERC165
    }

    function testProveOnlyCallableByPortal() public {
        bytes32[] memory intentHashes = new bytes32[](1);
        bytes32[] memory claimants = new bytes32[](1);
        intentHashes[0] = _hashIntent(intent);
        claimants[0] = bytes32(uint256(uint160(claimant)));

        // Should revert when called by non-portal (before the message is built)
        vm.expectRevert(PolymerPolicy.OnlyPortal.selector);
        polymerProver.prove(
            keeper,
            uint64(block.chainid),
            intentHashes,
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

        // Record the fulfillment so the prover can rebuild the identical wire message from its store
        _record(intentHashes, claimants);

        _expectEmit();
        emit PolymerPolicy.IntentFulfilledFromSource(
            uint64(block.chainid),
            encodedProofs
        );

        vm.prank(address(portal));
        polymerProver.prove(
            keeper,
            uint64(block.chainid),
            intentHashes,
            hex""
        );
    }

    function testProveHandlesEmptyProofs() public {
        vm.prank(address(portal));
        polymerProver.prove(
            keeper,
            uint64(block.chainid),
            new bytes32[](0),
            hex""
        );
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

        // Record each fulfillment so the prover rebuilds the identical wire message from its store
        _record(intentHashes, claimants);

        _expectEmit();
        emit PolymerPolicy.IntentFulfilledFromSource(
            uint64(block.chainid),
            encodedProofs
        );

        vm.prank(address(portal));
        polymerProver.prove(
            keeper,
            uint64(block.chainid),
            intentHashes,
            hex""
        );
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
        emit IPolicy.IntentProven(
            intentHash,
            OPTIMISM_CHAIN_ID,
            bytes32(uint256(uint160(claimant)))
        );

        polymerProver.validate(proof);

        IPolicy.ProofData memory proofData = polymerProver.provenIntents(
            intentHash
        );
        assertEq(proofData.fulfillmentHash, bytes32(uint256(uint160(claimant))));
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
        emit IPolicy.IntentAlreadyProven(intentHash);

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
        emit IPolicy.IntentProven(
            intentHashes[0],
            OPTIMISM_CHAIN_ID,
            bytes32(uint256(uint160(claimant)))
        );
        _expectEmit();
        emit IPolicy.IntentProven(
            intentHashes[1],
            OPTIMISM_CHAIN_ID,
            bytes32(uint256(uint160(claimant)))
        );
        _expectEmit();
        emit IPolicy.IntentProven(
            intentHashes[2],
            OPTIMISM_CHAIN_ID,
            bytes32(uint256(uint160(claimant)))
        );

        polymerProver.validate(proof);

        for (uint256 i = 0; i < 3; i++) {
            IPolicy.ProofData memory proofData = polymerProver.provenIntents(
                intentHashes[i]
            );
            assertEq(proofData.fulfillmentHash, bytes32(uint256(uint160(claimant))));
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
            IPolicy.ProofData memory proofData = polymerProver.provenIntents(
                intentHashes[i]
            );
            assertEq(
                proofData.fulfillmentHash,
                bytes32(uint256(uint160(claimants[i])))
            );
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
        emit IPolicy.IntentProven(
            intentHashes[0],
            OPTIMISM_CHAIN_ID,
            bytes32(uint256(uint160(claimant)))
        );
        _expectEmit();
        emit IPolicy.IntentProven(
            intentHashes[1],
            ARBITRUM_CHAIN_ID,
            bytes32(uint256(uint160(claimant)))
        );
        _expectEmit();
        emit IPolicy.IntentAlreadyProven(intentHashes[0]);

        polymerProver.validateBatch(proofs);

        for (uint256 i = 0; i < 2; i++) {
            IPolicy.ProofData memory proofData = polymerProver.provenIntents(
                intentHashes[i]
            );
            assertEq(
                proofData.fulfillmentHash,
                bytes32(uint256(uint160(claimants[i])))
            );
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
            keeper, // wrong contract
            topics,
            data
        );

        bytes memory proof = abi.encodePacked(uint256(1));

        vm.expectRevert(
            abi.encodeWithSelector(
                PolymerPolicy.InvalidEmittingContract.selector,
                keeper
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

        vm.expectRevert(PolymerPolicy.InvalidTopicsLength.selector);
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

        vm.expectRevert(PolymerPolicy.InvalidEventSignature.selector);
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

        IPolicy.ProofData memory proofData = polymerProver.provenIntents(
            intentHash
        );
        assertEq(proofData.fulfillmentHash, bytes32(uint256(uint160(claimant))));
        assertEq(proofData.destination, OPTIMISM_CHAIN_ID);

        // Challenge with different destination (intent.destination = 1 from BaseTest, proof.destination = 10)
        polymerProver.challengeIntentProof(
            intent.source,
            intent.destination, // 1
            keccak256(abi.encode(intent.route)),
            keccak256(abi.encode(intent.reward))
        );

        // Verify proof was cleared since destinations don't match
        proofData = polymerProver.provenIntents(intentHash);
        assertEq(proofData.fulfillmentHash, bytes32(0));
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
            localIntent.source,
            localIntent.destination,
            keccak256(abi.encode(localIntent.route)),
            keccak256(abi.encode(localIntent.reward))
        );

        // Verify proof is still there
        IPolicy.ProofData memory proofData = polymerProver.provenIntents(
            intentHash
        );
        assertEq(proofData.fulfillmentHash, bytes32(uint256(uint160(claimant))));
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

        PolymerPolicy newProver = new PolymerPolicy(
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
