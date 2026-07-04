// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {HyperPolicy} from "../../contracts/prover/HyperPolicy.sol";
import {MetaPolicy} from "../../contracts/prover/MetaPolicy.sol";
import {LayerZeroPolicy} from "../../contracts/prover/LayerZeroPolicy.sol";
import {TestPolicy} from "../../contracts/test/TestPolicy.sol";
import {TestMessagePolicy} from "../../contracts/test/TestMessagePolicy.sol";
import {IPolicy} from "../../contracts/interfaces/IPolicy.sol";
import {IMessageBridgePolicy} from "../../contracts/interfaces/IMessageBridgePolicy.sol";

contract ProverInterfaceTest is Test {
    TestPolicy testProver;
    TestMessagePolicy testMessageBridgeProver;

    function setUp() public {
        address portal = makeAddr("portal");
        testProver = new TestPolicy(portal);

        bytes32[] memory whitelistedProvers = new bytes32[](1);
        whitelistedProvers[0] = bytes32(uint256(uint160(makeAddr("prover"))));
        testMessageBridgeProver = new TestMessagePolicy(
            portal,
            whitelistedProvers,
            200000
        );
    }

    // Helper function to encode proofs with chain ID prefix
    function encodeProofsWithChainId(
        bytes32[] memory intentHashes,
        bytes32[] memory claimants
    ) internal view returns (bytes memory) {
        require(intentHashes.length == claimants.length, "Length mismatch");

        bytes memory encodedProofs = new bytes(8 + intentHashes.length * 64);
        uint64 chainId = uint64(block.chainid);

        assembly {
            // Store chain ID in first 8 bytes
            mstore(add(encodedProofs, 0x20), shl(192, chainId))
        }

        for (uint256 i = 0; i < intentHashes.length; i++) {
            assembly {
                let offset := add(8, mul(i, 64))
                mstore(
                    add(add(encodedProofs, 0x20), offset),
                    mload(add(intentHashes, add(0x20, mul(i, 32))))
                )
                mstore(
                    add(add(encodedProofs, 0x20), add(offset, 32)),
                    mload(add(claimants, add(0x20, mul(i, 32))))
                )
            }
        }

        return encodedProofs;
    }

    function testProverInterface() public {
        // Test encoding proofs
        bytes32[] memory intentHashes = new bytes32[](2);
        bytes32[] memory claimants = new bytes32[](2);

        intentHashes[0] = keccak256("intent1");
        intentHashes[1] = keccak256("intent2");
        claimants[0] = bytes32(uint256(uint160(makeAddr("claimant1"))));
        claimants[1] = bytes32(uint256(uint160(makeAddr("claimant2"))));

        // Encode proofs with chain ID prefix
        bytes memory encodedProofs = encodeProofsWithChainId(
            intentHashes,
            claimants
        );

        // Test that we can call prove with new interface
        testProver.receiveProofs(makeAddr("sender"), 1, encodedProofs, "");

        // Verify the prove call was tracked
        (
            address sender,
            uint256 sourceChainId,
            bytes memory data,
            uint256 value
        ) = testProver.args();
        assertEq(sender, makeAddr("sender"));
        assertEq(sourceChainId, 1);
        assertEq(data, "");
        assertEq(value, 0);
        assertEq(testProver.proveCallCount(), 1);

        // Verify the proofs were processed correctly by checking proven intents
        TestPolicy.ProofData memory proof1 = testProver.provenIntents(
            intentHashes[0]
        );
        TestPolicy.ProofData memory proof2 = testProver.provenIntents(
            intentHashes[1]
        );

        assertEq(proof1.fulfillmentHash, claimants[0]);
        assertEq(proof2.fulfillmentHash, claimants[1]);
        assertEq(proof1.destination, 1);
        assertEq(proof2.destination, 1);
    }

    function testFetchFeeInterface() public {
        bytes memory encodedProofs = new bytes(64); // 1 pair
        bytes memory data = abi.encode(
            bytes32(uint256(uint160(makeAddr("sourceProver"))))
        );

        uint256 fee = testMessageBridgeProver.fetchFee(1, encodedProofs, data);
        assertEq(fee, 100000); // Default fee amount
    }

    function testGetProofType() public view {
        assertEq(testProver.getProofType(), "storage");
        assertEq(
            testMessageBridgeProver.getProofType(),
            "TestMessagePolicy"
        );
    }

    // Edge Case Tests

    function testProveWithInvalidEncodingLength() public {
        // Test with 8 + 65 bytes (chain ID + invalid proof length)
        bytes memory invalidProofs = new bytes(8 + 65);
        uint64 chainId = uint64(block.chainid);
        assembly {
            mstore(add(invalidProofs, 0x20), shl(192, chainId))
        }

        vm.expectRevert(IPolicy.ArrayLengthMismatch.selector);
        testProver.receiveProofs(makeAddr("sender"), 1, invalidProofs, "");

        // Test with 8 + 63 bytes
        invalidProofs = new bytes(8 + 63);
        assembly {
            mstore(add(invalidProofs, 0x20), shl(192, chainId))
        }
        vm.expectRevert(IPolicy.ArrayLengthMismatch.selector);
        testProver.receiveProofs(makeAddr("sender"), 1, invalidProofs, "");

        // Test with just 7 bytes (less than chain ID)
        invalidProofs = new bytes(7);
        vm.expectRevert(IMessageBridgePolicy.InvalidProofMessage.selector);
        testProver.receiveProofs(makeAddr("sender"), 1, invalidProofs, "");
    }

    function testReceiveStoresNonzeroFulfillmentHashSkipsZero() public {
        // v3: the second word of each wire pair is a fulfillmentHash, not a claimant. It is stored
        // verbatim regardless of whether its low 20 bytes form a valid EVM address — claimant validity
        // is checked at settle, not at proof time. Only a ZERO second word is skipped defensively.
        bytes memory encodedProofs = new bytes(8 + 64);
        bytes32 intentHash = keccak256("intent1");
        // High bytes set: not a clean EVM address, but a valid nonzero fulfillmentHash.
        bytes32 nonEvmFulfillment = 0x0000000100000000000000000000000000000000000000000000000000000001;

        uint64 chainId = uint64(block.chainid);
        assembly {
            mstore(add(encodedProofs, 0x20), shl(192, chainId))
            mstore(add(encodedProofs, 0x28), intentHash)
            mstore(add(encodedProofs, 0x48), nonEvmFulfillment)
        }

        // A nonzero fulfillmentHash is stored (no proof-time claimant validation).
        testProver.receiveProofs(makeAddr("sender"), 1, encodedProofs, "");

        // Verify the intent WAS proven (commitment stored regardless of address form).
        TestPolicy.ProofData memory proof = testProver.provenIntents(
            intentHash
        );
        assertEq(proof.fulfillmentHash, nonEvmFulfillment);
        assertEq(proof.destination, 1);

        // A ZERO second word is skipped; use a fresh intent hash so the store starts empty.
        bytes32 zeroIntentHash = keccak256("intent-zero");
        assembly {
            mstore(add(encodedProofs, 0x28), zeroIntentHash)
            mstore(add(encodedProofs, 0x48), 0)
        }

        // Should succeed but skip the zero fulfillmentHash.
        testProver.receiveProofs(makeAddr("sender"), 1, encodedProofs, "");

        // Verify the fresh intent was NOT proven (zero commitment skipped).
        proof = testProver.provenIntents(zeroIntentHash);
        assertEq(proof.fulfillmentHash, bytes32(0));
        assertEq(proof.destination, 0);
    }

    function testProveStoresAllNonzeroFulfillmentHashesInBatch() public {
        // v3: every pair's second word is a fulfillmentHash stored verbatim; a high-bytes value is not
        // "invalid" at proof time (claimant validity is a settle-time check), so all three are stored.
        bytes32[] memory intentHashes = new bytes32[](3);
        intentHashes[0] = keccak256("intent1");
        intentHashes[1] = keccak256("intent2");
        intentHashes[2] = keccak256("intent3");

        bytes32[] memory claimants = new bytes32[](3);
        claimants[0] = bytes32(uint256(uint160(makeAddr("validClaimant"))));
        claimants[
            1
        ] = 0x0000000100000000000000000000000000000000000000000000000000000001; // high bytes set (non-EVM form)
        claimants[2] = bytes32(uint256(uint160(makeAddr("anotherValid"))));

        // Use helper to encode with chain ID
        bytes memory encodedProofs = encodeProofsWithChainId(
            intentHashes,
            claimants
        );

        // All three nonzero commitments are stored.
        testProver.receiveProofs(makeAddr("sender"), 1, encodedProofs, "");

        // Verify first proof was stored
        TestPolicy.ProofData memory proof1 = testProver.provenIntents(
            intentHashes[0]
        );
        assertEq(proof1.fulfillmentHash, claimants[0]);
        assertEq(proof1.destination, 1);

        // Verify second proof was stored verbatim (non-EVM-form commitment, no proof-time rejection)
        TestPolicy.ProofData memory proof2 = testProver.provenIntents(
            intentHashes[1]
        );
        assertEq(proof2.fulfillmentHash, claimants[1]);
        assertEq(proof2.destination, 1);

        // Verify third proof was stored
        TestPolicy.ProofData memory proof3 = testProver.provenIntents(
            intentHashes[2]
        );
        assertEq(proof3.fulfillmentHash, claimants[2]);
        assertEq(proof3.destination, 1);
    }

    function testProveWithCrossVMFulfillmentHash() public {
        // v3: a cross-VM fulfillmentHash (high bytes set) is stored verbatim on the receive side —
        // there is no proof-time EVM-address restriction. Claimant validity is enforced at settle.
        bytes32 intentHash = keccak256("crossVMIntent");
        bytes32 crossVMFulfillment = bytes32(
            uint256(
                0xFFFFFFFFFFFFFFFF000000000000000000000000000000000000000000000001
            )
        );

        bytes32[] memory hashes = new bytes32[](1);
        bytes32[] memory fulfillmentHashes = new bytes32[](1);
        hashes[0] = intentHash;
        fulfillmentHashes[0] = crossVMFulfillment;

        bytes memory encodedProofs = encodeProofsWithChainId(
            hashes,
            fulfillmentHashes
        );

        // Succeeds and stores the cross-VM commitment.
        testProver.receiveProofs(makeAddr("sender"), 1, encodedProofs, "");

        // Verify the intent WAS proven (fulfillmentHash stored regardless of address form).
        TestPolicy.ProofData memory proof = testProver.provenIntents(
            intentHash
        );
        assertEq(proof.fulfillmentHash, crossVMFulfillment);
        assertEq(proof.destination, 1);
    }

    function testProveLargeProofBatch() public {
        // Test with maximum reasonable batch size (100 proofs)
        uint256 numProofs = 100;

        bytes32[] memory intentHashes = new bytes32[](numProofs);
        bytes32[] memory claimants = new bytes32[](numProofs);

        for (uint256 i = 0; i < numProofs; i++) {
            intentHashes[i] = keccak256(abi.encodePacked("intent", i));
            claimants[i] = bytes32(
                uint256(uint160(address(uint160(i + 1000))))
            );
        }

        bytes memory encodedProofs = encodeProofsWithChainId(
            intentHashes,
            claimants
        );

        // Should process all proofs successfully
        testProver.receiveProofs(makeAddr("sender"), 1, encodedProofs, "");

        // Verify a few random proofs
        bytes32 checkHash = keccak256(abi.encodePacked("intent", uint256(50)));
        TestPolicy.ProofData memory proof = testProver.provenIntents(checkHash);
        assertEq(proof.fulfillmentHash, bytes32(uint256(1050)));
        assertEq(proof.destination, 1);
    }
}
