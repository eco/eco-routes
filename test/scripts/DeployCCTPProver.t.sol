// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../scripts/Deploy.s.sol";
import {CCTPProver} from "../../contracts/prover/CCTPProver.sol";
import {IMessageBridgeProver} from "../../contracts/interfaces/IMessageBridgeProver.sol";
import {MockDomainProver} from "../../contracts/test/MockDomainProver.sol";

contract DeployCCTPHarness is Deploy {
    function emptyContext()
        external
        pure
        returns (DeploymentContext memory ctx)
    {
        return ctx;
    }

    function exposedParseMaxPairs(
        string memory csv
    ) external pure returns (CCTPProver.MaxPairs[] memory) {
        return _parseMaxPairsConfig(csv);
    }

    function exposedWhitelist(
        DeploymentContext memory ctx,
        address preview
    ) external pure returns (bytes32[] memory) {
        return cctpProverWhitelist(ctx, preview);
    }

    function exposedValidate(DeploymentContext memory ctx) external view {
        validateAggregatorProverMembers(ctx);
    }

    function exposedRequireSolanaLaneCap(
        DeploymentContext memory ctx
    ) external pure {
        _requireSolanaLaneCap(ctx);
    }

    function exposedParseDomainConfig(
        string memory csv
    ) external pure returns (IMessageBridgeProver.Domain[] memory) {
        return _parseDomainConfig(csv);
    }
}

contract DeployCCTPProverTest is Test {
    DeployCCTPHarness internal harness;

    function setUp() public {
        harness = new DeployCCTPHarness();
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function test_parseMaxPairs() public view {
        CCTPProver.MaxPairs[] memory c = harness.exposedParseMaxPairs(
            "5:7,2:40"
        );
        assertEq(c.length, 2);
        assertEq(c[0].domain, 5);
        assertEq(c[0].maxPairs, 7);
        assertEq(c[1].domain, 2);
        assertEq(c[1].maxPairs, 40);
    }

    function test_parseMaxPairs_emptyIsEmpty() public view {
        assertEq(harness.exposedParseMaxPairs("").length, 0);
    }

    function test_parseMaxPairs_rejectsZero() public {
        vm.expectRevert(
            bytes("CCTP_MAX_PAIRS_CONFIG maxPairs must be 1..65535")
        );
        harness.exposedParseMaxPairs("5:0");
    }

    function test_parseMaxPairs_rejectsDomainAboveUint32() public {
        vm.expectRevert(bytes("CCTP_MAX_PAIRS_CONFIG domain exceeds uint32"));
        harness.exposedParseMaxPairs("4294967296:7");
    }

    function test_domainConfigParserAcceptsDomainZero() public view {
        IMessageBridgeProver.Domain[] memory d = harness
            .exposedParseDomainConfig("0:1,3:42161");
        assertEq(d[0].domain, 0);
        assertEq(d[0].chainId, 1);
    }

    /// Review Focus 2: CCTP reports EVM senders left-padded.
    function test_whitelistSelfIsLeftPadded() public view {
        Deploy.DeploymentContext memory ctx = harness.emptyContext();
        address preview = address(0xC0FFEE);
        bytes32[] memory w = harness.exposedWhitelist(ctx, preview);
        assertEq(w.length, 1);
        assertEq(w[0], _b32(preview));
        assertTrue(w[0] != bytes32(bytes20(preview)));
    }

    function test_whitelistAppendsCrossVmProvers() public view {
        Deploy.DeploymentContext memory ctx = harness.emptyContext();
        ctx.cctpCrossVmProvers = new bytes32[](1);
        ctx.cctpCrossVmProvers[0] = bytes32(uint256(0xABCD) << 128);
        bytes32[] memory w = harness.exposedWhitelist(ctx, address(0xC0FFEE));
        assertEq(w.length, 2);
        assertEq(w[1], ctx.cctpCrossVmProvers[0]);
    }

    function test_whitelistRejectsOverCap() public {
        Deploy.DeploymentContext memory ctx = harness.emptyContext();
        ctx.cctpCrossVmProvers = new bytes32[](20);
        for (uint256 i = 0; i < 20; i++)
            ctx.cctpCrossVmProvers[i] = bytes32(i + 1);
        vm.expectRevert(
            bytes("CCTP_CROSS_VM_PROVERS + self exceed the 20-slot whitelist")
        );
        harness.exposedWhitelist(ctx, address(0xC0FFEE));
    }

    function test_validateAcceptsCctpMemberWithDomainZeroLane() public {
        MockDomainProver member = new MockDomainProver();
        member.setDomain(0, 1);
        member.setDomain(3, 42161);
        Deploy.DeploymentContext memory ctx = harness.emptyContext();
        ctx.aggregatorProverMembers = new bytes32[](1);
        ctx.aggregatorProverMembers[0] = _b32(address(member));
        ctx.cctpProver = address(member);
        ctx.cctpDomainConfig = harness.exposedParseDomainConfig("0:1,3:42161");
        harness.exposedValidate(ctx);
    }

    function test_validateRejectsCctpMemberWithMismatchedLane() public {
        MockDomainProver member = new MockDomainProver();
        member.setDomain(0, 1);
        Deploy.DeploymentContext memory ctx = harness.emptyContext();
        ctx.aggregatorProverMembers = new bytes32[](1);
        ctx.aggregatorProverMembers[0] = _b32(address(member));
        ctx.cctpProver = address(member);
        ctx.cctpDomainConfig = harness.exposedParseDomainConfig("0:10");
        vm.expectRevert(
            bytes("member domain map disagrees with configured lane")
        );
        harness.exposedValidate(ctx);
    }

    function test_validateAcceptsCctpMemberWithEmptyConfig() public {
        MockDomainProver member = new MockDomainProver();
        Deploy.DeploymentContext memory ctx = harness.emptyContext();
        ctx.aggregatorProverMembers = new bytes32[](1);
        ctx.aggregatorProverMembers[0] = _b32(address(member));
        ctx.cctpProver = address(member);
        harness.exposedValidate(ctx); // strict map: no explicit lanes required
    }

    function test_solanaLaneCap_revertsWhenListedWithoutCap() public {
        Deploy.DeploymentContext memory ctx = harness.emptyContext();
        ctx.cctpDomainConfig = harness.exposedParseDomainConfig(
            "0:1,5:1399811149"
        );
        vm.expectRevert(
            bytes(
                "CCTP_MAX_PAIRS_CONFIG must cap domain 5 (Solana) when CCTP_DOMAIN_CONFIG lists it"
            )
        );
        harness.exposedRequireSolanaLaneCap(ctx);
    }

    function test_solanaLaneCap_passesWhenCapped() public view {
        Deploy.DeploymentContext memory ctx = harness.emptyContext();
        ctx.cctpDomainConfig = harness.exposedParseDomainConfig(
            "0:1,5:1399811149"
        );
        ctx.cctpMaxPairsConfig = harness.exposedParseMaxPairs("5:6");
        harness.exposedRequireSolanaLaneCap(ctx);
    }

    function test_solanaLaneCap_passesWithoutSolana() public view {
        Deploy.DeploymentContext memory ctx = harness.emptyContext();
        ctx.cctpDomainConfig = harness.exposedParseDomainConfig("0:1,3:42161");
        harness.exposedRequireSolanaLaneCap(ctx);
    }
}
