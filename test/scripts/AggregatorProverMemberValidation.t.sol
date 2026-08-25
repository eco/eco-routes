// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../scripts/Deploy.s.sol";
import {IMessageBridgeProver} from "../../contracts/interfaces/IMessageBridgeProver.sol";
import {MockDomainProver} from "../../contracts/test/MockDomainProver.sol";
import {MockDomainProverMalformedProvenIntents} from "../../contracts/test/MockDomainProverMalformedProvenIntents.sol";
import {MockDomainProverDirtyChainId} from "../../contracts/test/MockDomainProverDirtyChainId.sol";
import {MockDomainProverEmptyDynamic} from "../../contracts/test/MockDomainProverEmptyDynamic.sol";
import {TestProver} from "../../contracts/test/TestProver.sol";
import {TestMailbox} from "../../contracts/test/TestMailbox.sol";
import {Portal} from "../../contracts/Portal.sol";
import {HyperProver} from "../../contracts/prover/HyperProver.sol";

/// @dev Harness exposing Deploy's internal validator and member-list parser
///      to tests
contract DeployHarness is Deploy {
    function exposedValidate(DeploymentContext memory ctx) external view {
        validateAggregatorProverMembers(ctx);
    }

    function emptyContext()
        external
        pure
        returns (DeploymentContext memory ctx)
    {
        return ctx;
    }

    function exposedParseAggregatorProverMembers(
        string memory csv
    ) external pure returns (bytes32[] memory) {
        return _parseAggregatorProverMembers(csv);
    }
}

contract AggregatorProverMemberValidationTest is Test {
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
        ctx.aggregatorProverMembers = members;
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

    /// @dev These two cases were previously merged into one function because
    ///      they were driven by vm.setEnv, which mutates the REAL process
    ///      environment (Foundry does not sandbox it per test) and raced under
    ///      the parallel runner. The hatch is now read once in run() into
    ///      ctx.allowUnverifiedMembers, so each case sets a struct field on its
    ///      own ctx and they can be independent tests again. That also removes
    ///      the sharper hazard the merge left behind: a revert partway through
    ///      the merged function skipped the env restore, leaving the hatch ON
    ///      for the rest of the process and turning one genuine failure into a
    ///      cascade of false greens.
    function test_rejectsUnknownMemberWithoutEscapeHatch() public {
        MockDomainProver unknown = new MockDomainProver();
        Deploy.DeploymentContext memory ctx = _ctxWith(
            _one(_b32(address(unknown)))
        );
        // hyperProver stays pointed at `hyper` from _ctxWith, so `unknown`
        // matches none of hyperProver/metaProver/layerZeroProver.
        ctx.allowUnverifiedMembers = false;

        vm.expectRevert(bytes("member is not a prover deployed in this run"));
        harness.exposedValidate(ctx);
    }

    function test_acceptsUnknownMemberWithEscapeHatch() public {
        MockDomainProver unknown = new MockDomainProver();
        Deploy.DeploymentContext memory ctx = _ctxWith(
            _one(_b32(address(unknown)))
        );
        ctx.allowUnverifiedMembers = true;

        harness.exposedValidate(ctx);
    }

    /// @dev Regression pin for the strict-decode trap in _tryChainIdByDomain.
    ///      Before the fix the probe did `abi.decode(ret, (uint64))`, which is
    ///      strict: a member returning a word with non-zero upper bits made the
    ///      PROBE ITSELF revert, in the script's own frame with no try/catch to
    ///      land in, aborting the whole deploy with a bare decode error rather
    ///      than surfacing the intended require. The probe now decodes wide and
    ///      range-checks, so this member is cleanly REJECTED with the real
    ///      message. If the strict decode is reintroduced this test fails with
    ///      a decode revert instead of this expected string.
    function test_rejectsMemberWithDirtyChainIdByDomain() public {
        MockDomainProverDirtyChainId dirty = new MockDomainProverDirtyChainId();
        Deploy.DeploymentContext memory ctx = _ctxWith(
            _one(_b32(address(dirty)))
        );

        vm.expectRevert(
            bytes(
                "member does not expose chainIdByDomain; destination not bridge-attested"
            )
        );
        harness.exposedValidate(ctx);
    }

    /// @dev Regression pin for the empty-dynamic gap in _tryProvenIntentsShape.
    ///      An empty `bytes` return encodes to exactly 64 bytes (offset 0x20,
    ///      length 0x00), so it passes both the length check and the old range
    ///      check (0x20 >> 160 == 0). AggregatorProver.provenIntents rejects
    ///      that same payload at runtime via its zero-destination guard, so the
    ///      member would be skipped for EVERY intentHash forever — and
    ///      membership is immutable. The probe now requires both words to be
    ///      exactly zero, which an honest member satisfies because bytes32(0)
    ///      is an unproven hash.
    function test_rejectsMemberWithEmptyDynamicProvenIntents() public {
        MockDomainProverEmptyDynamic bad = new MockDomainProverEmptyDynamic();
        Deploy.DeploymentContext memory ctx = _ctxWith(_one(_b32(address(bad))));
        ctx.hyperProver = address(bad);

        vm.expectRevert(
            bytes(
                "member provenIntents does not return a well-formed ProofData"
            )
        );
        harness.exposedValidate(ctx);
    }

    /// @dev Pins the Fix-2 hardening: a member exposing chainIdByDomain (so
    ///      it clears the bridge-attestation probe) but whose provenIntents
    ///      returns the wrong shape (32 bytes instead of the 64-byte
    ///      ProofData encoding) must be rejected at DEPLOY time, since
    ///      AggregatorProver.provenIntents would otherwise silently skip it forever
    ///      at runtime — and membership is immutable, so this is the last
    ///      point such a member can be caught.
    function test_rejectsMalformedProvenIntentsShape() public {
        MockDomainProverMalformedProvenIntents bad = new MockDomainProverMalformedProvenIntents();
        Deploy.DeploymentContext memory ctx = _ctxWith(
            _one(_b32(address(bad)))
        );
        // Matched branch, empty domain config: reaches the provenIntents
        // shape probe without needing per-lane domain setup.
        ctx.hyperProver = address(bad);

        vm.expectRevert(
            bytes(
                "member provenIntents does not return a well-formed ProofData"
            )
        );
        harness.exposedValidate(ctx);
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

    /// @dev Pins the Fix-3 hardening: AGGREGATOR_PROVER_MEMBERS accepts the
    ///      20-byte address form operators will actually write (Foundry's
    ///      strict vm.envBytes32 previously rejected this form outright,
    ///      and the try/catch it sat behind silently discarded the whole
    ///      list on that rejection).
    function test_parseAggregatorProverMembers_acceptsAddressForm()
        public
        view
    {
        string memory csv = vm.toString(address(0xBEEF));
        bytes32[] memory members = harness.exposedParseAggregatorProverMembers(
            csv
        );
        assertEq(members.length, 1);
        assertEq(members[0], _b32(address(0xBEEF)));
    }

    /// @dev The full 32-byte bytes32 form (needed for non-EVM cross-VM
    ///      members elsewhere in the repo) must still be accepted.
    function test_parseAggregatorProverMembers_acceptsBytes32Form()
        public
        view
    {
        bytes32 expected = _b32(address(0xCAFE));
        string memory csv = vm.toString(expected);
        bytes32[] memory members = harness.exposedParseAggregatorProverMembers(
            csv
        );
        assertEq(members.length, 1);
        assertEq(members[0], expected);
    }

    function test_parseAggregatorProverMembers_acceptsMixedAddressAndBytes32Forms()
        public
        view
    {
        string memory csv = string(
            abi.encodePacked(
                vm.toString(address(0xBEEF)),
                ",",
                vm.toString(_b32(address(0xCAFE)))
            )
        );
        bytes32[] memory members = harness.exposedParseAggregatorProverMembers(
            csv
        );
        assertEq(members.length, 2);
        assertEq(members[0], _b32(address(0xBEEF)));
        assertEq(members[1], _b32(address(0xCAFE)));
    }

    /// @dev A malformed element must fail the deploy LOUDLY, never fall back
    ///      to an empty list the way the old try/catch did.
    function test_parseAggregatorProverMembers_revertsOnMalformedElement()
        public
    {
        vm.expectRevert(
            bytes(
                "AGGREGATOR_PROVER_MEMBERS: malformed element at index 0: '0xnotvalid' (expected a 20-byte address or 32-byte bytes32)"
            )
        );
        harness.exposedParseAggregatorProverMembers("0xnotvalid");
    }

    /// @dev Confirms the reported index tracks the ACTUAL offending element,
    ///      not just index 0, in a multi-element list.
    function test_parseAggregatorProverMembers_revertsOnMalformedElementAtNonZeroIndex()
        public
    {
        string memory csv = string(
            abi.encodePacked(vm.toString(address(0xBEEF)), ",0xnotvalid")
        );
        vm.expectRevert(
            bytes(
                "AGGREGATOR_PROVER_MEMBERS: malformed element at index 1: '0xnotvalid' (expected a 20-byte address or 32-byte bytes32)"
            )
        );
        harness.exposedParseAggregatorProverMembers(csv);
    }

    /// @dev A trailing comma splits into a final empty element. The old
    ///      vm.envBytes32-based parser rejected a trailing comma outright,
    ///      and its try/catch silently discarded the whole configured list
    ///      on that rejection. This must now fail loudly instead.
    function test_parseAggregatorProverMembers_revertsOnTrailingComma() public {
        string memory csv = string(
            abi.encodePacked(vm.toString(address(0xBEEF)), ",")
        );
        vm.expectRevert(
            bytes(
                "AGGREGATOR_PROVER_MEMBERS: malformed element at index 1: '' (expected a 20-byte address or 32-byte bytes32)"
            )
        );
        harness.exposedParseAggregatorProverMembers(csv);
    }
}
