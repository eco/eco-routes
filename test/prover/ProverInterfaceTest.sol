// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {HyperProver} from "../../contracts/prover/HyperProver.sol";
import {MetaProver} from "../../contracts/prover/MetaProver.sol";
import {LayerZeroProver} from "../../contracts/prover/LayerZeroProver.sol";
import {TestProver} from "../../contracts/test/TestProver.sol";
import {TestMessageBridgeProver} from "../../contracts/test/TestMessageBridgeProver.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";

contract ProverInterfaceTest is Test {
    TestProver testProver;
    TestMessageBridgeProver testMessageBridgeProver;

    function setUp() public {
        address portal = makeAddr("portal");
        testProver = new TestProver(portal);

        bytes32[] memory whitelistedProvers = new bytes32[](1);
        whitelistedProvers[0] = bytes32(uint256(uint160(makeAddr("prover"))));
        testMessageBridgeProver = new TestMessageBridgeProver(
            portal,
            whitelistedProvers,
            200000
        );
    }

    function testProverInterface() public {
        // Test encoding proofs
        bytes32[] memory intentHashes = new bytes32[](2);
        bytes32[] memory claimants = new bytes32[](2);

        intentHashes[0] = keccak256("intent1");
        intentHashes[1] = keccak256("intent2");
        claimants[0] = bytes32(uint256(uint160(makeAddr("claimant1"))));
        claimants[1] = bytes32(uint256(uint160(makeAddr("claimant2"))));

        // Encode proofs manually
        bytes memory encodedProofs = new bytes(128); // 2 pairs * 64 bytes each
        assembly {
            // First pair: intent1 + claimant1
            mstore(add(encodedProofs, 0x20), mload(add(intentHashes, 0x20)))
            mstore(add(encodedProofs, 0x40), mload(add(claimants, 0x20)))
            // Second pair: intent2 + claimant2
            mstore(add(encodedProofs, 0x60), mload(add(intentHashes, 0x40)))
            mstore(add(encodedProofs, 0x80), mload(add(claimants, 0x40)))
        }

        // Test that we can call prove with new interface
        testProver.prove(makeAddr("sender"), 1, encodedProofs, "");

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
        TestProver.ProofData memory proof1 = testProver.provenIntents(
            intentHashes[0]
        );
        TestProver.ProofData memory proof2 = testProver.provenIntents(
            intentHashes[1]
        );

        assertEq(proof1.claimant, address(uint160(uint256(claimants[0]))));
        assertEq(proof2.claimant, address(uint160(uint256(claimants[1]))));
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
            "TestMessageBridgeProver"
        );
    }
}
