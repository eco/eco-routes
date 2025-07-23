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
            // First pair: claimant1 + intent1
            mstore(add(encodedProofs, 0x20), mload(add(claimants, 0x20)))
            mstore(add(encodedProofs, 0x40), mload(add(intentHashes, 0x20)))
            // Second pair: claimant2 + intent2
            mstore(add(encodedProofs, 0x60), mload(add(claimants, 0x40)))
            mstore(add(encodedProofs, 0x80), mload(add(intentHashes, 0x40)))
        }

        // Test that we can call prove with new interface
        testProver.prove(makeAddr("sender"), 1, encodedProofs, "");

        // Verify the data was extracted correctly
        assertEq(testProver.argIntentHashes(0), intentHashes[0]);
        assertEq(testProver.argIntentHashes(1), intentHashes[1]);
        assertEq(testProver.argClaimants(0), claimants[0]);
        assertEq(testProver.argClaimants(1), claimants[1]);
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
