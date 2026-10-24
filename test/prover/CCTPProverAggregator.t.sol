// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {AggregatorProver} from "../../contracts/prover/AggregatorProver.sol";
import {CCTPProver} from "../../contracts/prover/CCTPProver.sol";
import {MockMessageTransmitterV2} from "../../contracts/test/MockMessageTransmitterV2.sol";
import {IMessageBridgeProver} from "../../contracts/interfaces/IMessageBridgeProver.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";

contract CCTPProverAggregatorTest is BaseTest {
    bytes32 internal constant PEER =
        bytes32(uint256(uint160(0x1234567890123456789012345678901234567890)));
    uint32 internal constant ARB_DOMAIN = 3;
    uint64 internal constant ARB_CHAIN_ID = 42161;

    MockMessageTransmitterV2 internal transmitter;
    CCTPProver internal cctp;
    AggregatorProver internal aggregator;

    function setUp() public override {
        super.setUp();
        transmitter = new MockMessageTransmitterV2(6);
        bytes32[] memory provers = new bytes32[](1);
        provers[0] = PEER;
        IMessageBridgeProver.Domain[]
            memory d = new IMessageBridgeProver.Domain[](1);
        d[0] = IMessageBridgeProver.Domain({
            domain: ARB_DOMAIN,
            chainId: ARB_CHAIN_ID
        });
        cctp = new CCTPProver(
            address(portal),
            address(transmitter),
            provers,
            d,
            new CCTPProver.MaxPairs[](0)
        );

        bytes32[] memory members = new bytes32[](2);
        members[0] = bytes32(uint256(uint160(address(prover)))); // TestProver, higher priority
        members[1] = bytes32(uint256(uint160(address(cctp))));
        aggregator = new AggregatorProver(members);
    }

    function test_aggregatorSeesCctpProofWhenHigherMemberEmpty() public {
        bytes32 h = keccak256("agg-intent");
        address solver = makeAddr("solver");
        transmitter.deliver(
            address(cctp),
            ARB_DOMAIN,
            PEER,
            1000,
            abi.encodePacked(ARB_CHAIN_ID, h, bytes32(uint256(uint160(solver))))
        );

        IProver.ProofData memory p = aggregator.provenIntents(h);
        assertEq(p.claimant, solver);
        assertEq(p.destination, ARB_CHAIN_ID);
    }
}
