// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../scripts/Deploy.s.sol";
import {IMessageBridgeProver} from "../../contracts/interfaces/IMessageBridgeProver.sol";
import {MockDomainProver} from "../../contracts/test/MockDomainProver.sol";
import {TestProver} from "../../contracts/test/TestProver.sol";
import {TestMailbox} from "../../contracts/test/TestMailbox.sol";
import {Portal} from "../../contracts/Portal.sol";
import {HyperProver} from "../../contracts/prover/HyperProver.sol";

/// @dev Harness exposing Deploy's internal validator to tests
contract DeployHarness is Deploy {
    function exposedValidate(DeploymentContext memory ctx) external view {
        validateAggregatorMembers(ctx);
    }

    function emptyContext()
        external
        pure
        returns (DeploymentContext memory ctx)
    {
        return ctx;
    }
}

contract AggregatorMemberValidationTest is Test {
    DeployHarness internal harness;
    MockDomainProver internal hyper;

    function setUp() public {
        harness = new DeployHarness();
        hyper = new MockDomainProver();
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _ctxWith(
        bytes32[] memory members
    ) internal view returns (Deploy.DeploymentContext memory ctx) {
        ctx = harness.emptyContext();
        ctx.aggregatorMembers = members;
        ctx.hyperProver = address(hyper);
    }

    function _one(bytes32 m) internal pure returns (bytes32[] memory a) {
        a = new bytes32[](1);
        a[0] = m;
    }

    function test_rejectsCodelessMember() public {
        Deploy.DeploymentContext memory ctx = _ctxWith(
            _one(_b32(address(0xDEAD)))
        );

        vm.expectRevert(bytes("member has no code on this chain"));
        harness.exposedValidate(ctx);
    }

    function test_rejectsZeroMember() public {
        Deploy.DeploymentContext memory ctx = _ctxWith(_one(bytes32(0)));

        vm.expectRevert(bytes("member is zero address"));
        harness.exposedValidate(ctx);
    }

    function test_rejectsNonEvmMember() public {
        Deploy.DeploymentContext memory ctx = _ctxWith(
            _one(bytes32(type(uint256).max))
        );

        vm.expectRevert(bytes("member is not an EVM address"));
        harness.exposedValidate(ctx);
    }

    function test_rejectsPolymerProver() public {
        // Uses MockDomainProver (which exposes chainIdByDomain), not a real
        // PolymerProver, deliberately: a real PolymerProver has no
        // chainIdByDomain and would already be rejected one line earlier by
        // the unconditional probe, never reaching the Polymer-specific check
        // this test targets.
        MockDomainProver polymer = new MockDomainProver();
        Deploy.DeploymentContext memory ctx = _ctxWith(
            _one(_b32(address(polymer)))
        );
        ctx.polymerProver = address(polymer);

        vm.expectRevert(
            bytes("PolymerProver destination is not bridge-attested")
        );
        harness.exposedValidate(ctx);
    }

    function test_rejectsMemberWithoutChainIdByDomain() public {
        Portal portal = new Portal(address(0));
        TestProver noDomainProver = new TestProver(address(portal));
        Deploy.DeploymentContext memory ctx = _ctxWith(
            _one(_b32(address(noDomainProver)))
        );

        vm.expectRevert(
            bytes(
                "member does not expose chainIdByDomain; destination not bridge-attested"
            )
        );
        harness.exposedValidate(ctx);
    }

    // Cases 6 and 7 are combined into one test, deliberately.
    //
    // vm.setEnv mutates the REAL process environment, which Foundry does not
    // sandbox per test. `forge test` defaults to running test functions
    // concurrently across threads (`--threads` defaults to the logical core
    // count), so a case reading the ambient default (case 6, "no escape
    // hatch") raced against a sibling case that flips the same env var to
    // "true" partway through its run (case 7) is not a rare flake: it was
    // observed failing on essentially every run of
    // `forge test --match-contract AggregatorMemberValidationTest`, and only
    // passed reliably under `--threads 1`. Ordering the two assertions inside
    // a single test function makes them run sequentially by construction,
    // which removes the race without weakening either assertion (the
    // negative case still asserts the exact revert string; the positive case
    // still asserts no revert). See the task report for detail.
    function test_escapeHatchGatesUnknownMembers() public {
        // Defensive: pin the ambient value before asserting the default
        // (no-escape-hatch) behavior, in case a prior run in this process
        // left it set.
        vm.setEnv("AGGREGATOR_ALLOW_UNVERIFIED_MEMBERS", "false");

        MockDomainProver unknown = new MockDomainProver();
        Deploy.DeploymentContext memory ctx = _ctxWith(
            _one(_b32(address(unknown)))
        );
        // hyperProver stays pointed at `hyper` from _ctxWith, so `unknown`
        // matches none of hyperProver/metaProver/layerZeroProver.

        // Case 6: rejected without the escape hatch.
        vm.expectRevert(bytes("member is not a prover deployed in this run"));
        harness.exposedValidate(ctx);

        // Case 7: accepted once the escape hatch is enabled.
        vm.setEnv("AGGREGATOR_ALLOW_UNVERIFIED_MEMBERS", "true");
        harness.exposedValidate(ctx);

        vm.setEnv("AGGREGATOR_ALLOW_UNVERIFIED_MEMBERS", "false");
    }

    function test_rejectsDomainMapMismatch() public {
        Deploy.DeploymentContext memory ctx = _ctxWith(
            _one(_b32(address(hyper)))
        );
        ctx.hyperProver = address(hyper);
        ctx.hyperDomainConfig = new IMessageBridgeProver.Domain[](1);
        ctx.hyperDomainConfig[0] = IMessageBridgeProver.Domain({
            domain: 100,
            chainId: 10
        });
        hyper.setDomain(100, 999);

        vm.expectRevert(
            bytes("member domain map disagrees with configured lane")
        );
        harness.exposedValidate(ctx);
    }

    function test_acceptsMatchingDomainMap() public {
        Deploy.DeploymentContext memory ctx = _ctxWith(
            _one(_b32(address(hyper)))
        );
        ctx.hyperProver = address(hyper);
        ctx.hyperDomainConfig = new IMessageBridgeProver.Domain[](1);
        ctx.hyperDomainConfig[0] = IMessageBridgeProver.Domain({
            domain: 100,
            chainId: 10
        });
        hyper.setDomain(100, 10);

        harness.exposedValidate(ctx);
    }

    /// @dev Directly pins that the chainIdByDomain probe runs UNCONDITIONALLY,
    ///      rather than being (accidentally) folded into the per-lane
    ///      domains-loop below it. Unlike test_rejectsMemberWithoutChainIdByDomain
    ///      (an unmatched member, routed through the escape-hatch branch), this
    ///      member IS ctx.hyperProver — the matched branch — with an EMPTY
    ///      hyperDomainConfig, so the per-lane loop never executes either way.
    ///      If the probe were wrongly folded into that loop instead of running
    ///      unconditionally, this case would wrongly pass; pinning it here
    ///      does not lean on the sibling test's (different) code path.
    function test_unconditionalProbeRunsForMatchedMemberWithEmptyDomainConfig()
        public
    {
        Portal portal = new Portal(address(0));
        TestProver noDomainProver = new TestProver(address(portal));
        Deploy.DeploymentContext memory ctx = _ctxWith(
            _one(_b32(address(noDomainProver)))
        );
        // Matched branch, not the escape hatch: member IS ctx.hyperProver.
        ctx.hyperProver = address(noDomainProver);
        // ctx.hyperDomainConfig intentionally left empty.

        vm.expectRevert(
            bytes(
                "member does not expose chainIdByDomain; destination not bridge-attested"
            )
        );
        harness.exposedValidate(ctx);
    }

    function test_acceptsEmptyDomainConfig() public view {
        Deploy.DeploymentContext memory ctx = _ctxWith(
            _one(_b32(address(hyper)))
        );
        ctx.hyperProver = address(hyper);
        // ctx.hyperDomainConfig left empty on purpose: HYPER_DOMAIN_CONFIG is
        // exceptions-only and legitimately unset for the default configuration.
        // The unconditional chainIdByDomain(0) probe above still runs and must
        // pass for `hyper` regardless.

        harness.exposedValidate(ctx);
    }

    /// @dev Every other test in this file uses MockDomainProver, which
    ///      REIMPLEMENTS chainIdByDomain(uint64) returns (uint64) rather than
    ///      inheriting it — so none of them pin the actual signature exposed
    ///      by real MessageBridgeProver descendants. This test uses a real
    ///      HyperProver (built the same way test/prover/HyperProver.t.sol
    ///      does) so validation is checked against the real function, not a
    ///      mock's reimplementation of it.
    function test_acceptsRealMessageBridgeProverDescendant() public {
        Portal portal = new Portal(address(0));
        TestMailbox mailbox = new TestMailbox(address(0));

        bytes32[] memory hyperProvers = new bytes32[](1);
        hyperProvers[0] = _b32(address(0xBEEF));

        IMessageBridgeProver.Domain[]
            memory domainConfig = new IMessageBridgeProver.Domain[](1);
        domainConfig[0] = IMessageBridgeProver.Domain({
            domain: 100,
            chainId: 10
        });

        HyperProver realHyper = new HyperProver(
            address(mailbox),
            address(portal),
            hyperProvers,
            domainConfig
        );

        Deploy.DeploymentContext memory ctx = _ctxWith(
            _one(_b32(address(realHyper)))
        );
        ctx.hyperProver = address(realHyper);
        ctx.hyperDomainConfig = domainConfig;

        // Must not revert: real MessageBridgeProver descendant, matched
        // branch, lane matches the deployed contract's own domain config.
        harness.exposedValidate(ctx);
    }
}
