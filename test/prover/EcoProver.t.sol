// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {EcoProver} from "../../contracts/prover/EcoProver.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {Portal} from "../../contracts/Portal.sol";
import {TestProver} from "../../contracts/test/TestProver.sol";
import {RevertingProver} from "../../contracts/test/RevertingProver.sol";
import {MalformedProver} from "../../contracts/test/MalformedProver.sol";
import {DirtyBitsProver} from "../../contracts/test/DirtyBitsProver.sol";
import {EmptyDynamicProver} from "../../contracts/test/EmptyDynamicProver.sol";
import {Whitelist} from "../../contracts/libs/Whitelist.sol";

contract EcoProverTest is Test {
    Portal internal portal;
    TestProver internal proverA;
    TestProver internal proverB;
    EcoProver internal aggregator;

    bytes32 internal constant HASH = keccak256("intent");
    uint64 internal constant DESTINATION = 8453;
    uint64 internal constant WRONG_DESTINATION = 999;

    event MemberRegistered(address indexed member, uint256 indexed priority);

    function setUp() public {
        portal = new Portal(address(0));
        proverA = new TestProver(address(portal));
        proverB = new TestProver(address(portal));
        aggregator = new EcoProver(_pair(address(proverA), address(proverB)));

        // test_prove_alwaysReverts sends value
        vm.deal(address(this), 1 ether);
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _pair(
        address a,
        address b
    ) internal pure returns (bytes32[] memory m) {
        m = new bytes32[](2);
        m[0] = _b32(a);
        m[1] = _b32(b);
    }

    function _triple(
        address a,
        address b,
        address c
    ) internal pure returns (bytes32[] memory m) {
        m = new bytes32[](3);
        m[0] = _b32(a);
        m[1] = _b32(b);
        m[2] = _b32(c);
    }

    function test_constructor_registersMembersInPriorityOrder() public view {
        address[] memory members = aggregator.getMembers();
        assertEq(members.length, 2);
        assertEq(members[0], address(proverA));
        assertEq(members[1], address(proverB));
    }

    function test_constructor_emitsMemberRegistered() public {
        vm.expectEmit(true, true, false, false);
        emit MemberRegistered(address(proverA), 0);
        vm.expectEmit(true, true, false, false);
        emit MemberRegistered(address(proverB), 1);
        new EcoProver(_pair(address(proverA), address(proverB)));
    }

    function test_constructor_revertsOnEmptySet() public {
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert(
            abi.encodeWithSelector(EcoProver.InvalidMemberSet.selector, 0, 8)
        );
        new EcoProver(empty);
    }

    function test_constructor_revertsOnOversizedSet() public {
        bytes32[] memory nine = new bytes32[](9);
        for (uint256 i = 0; i < 9; ++i) {
            nine[i] = bytes32(uint256(i + 1));
        }
        vm.expectRevert(
            abi.encodeWithSelector(EcoProver.InvalidMemberSet.selector, 9, 8)
        );
        new EcoProver(nine);
    }

    function test_constructor_revertsAboveWhitelistCapWithWhitelistError()
        public
    {
        bytes32[] memory twentyOne = new bytes32[](21);
        for (uint256 i = 0; i < 21; ++i) {
            twentyOne[i] = bytes32(uint256(i + 1));
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                Whitelist.WhitelistSizeExceeded.selector,
                21,
                20
            )
        );
        new EcoProver(twentyOne);
    }

    function test_constructor_revertsOnZeroMember() public {
        bytes32[] memory members = _pair(address(proverA), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(EcoProver.InvalidMember.selector, bytes32(0))
        );
        new EcoProver(members);
    }

    function test_constructor_revertsOnNonEvmMember() public {
        bytes32 nonEvm = bytes32(type(uint256).max);
        bytes32[] memory members = new bytes32[](2);
        members[0] = _b32(address(proverA));
        members[1] = nonEvm;
        vm.expectRevert(
            abi.encodeWithSelector(EcoProver.InvalidMember.selector, nonEvm)
        );
        new EcoProver(members);
    }

    function test_constructor_revertsOnDuplicateMember() public {
        bytes32[] memory members = _pair(address(proverA), address(proverA));
        vm.expectRevert(
            abi.encodeWithSelector(
                EcoProver.DuplicateMember.selector,
                _b32(address(proverA))
            )
        );
        new EcoProver(members);
    }

    function test_constructor_acceptsMaxMembersSet() public {
        uint256 maxMembers = aggregator.MAX_MEMBERS();
        bytes32[] memory eight = new bytes32[](maxMembers);
        for (uint256 i = 0; i < maxMembers; ++i) {
            eight[i] = bytes32(uint256(i + 1));
        }
        EcoProver agg = new EcoProver(eight);
        address[] memory members = agg.getMembers();
        assertEq(members.length, maxMembers);
        for (uint256 i = 0; i < maxMembers; ++i) {
            assertEq(members[i], address(uint160(i + 1)));
        }
    }

    function test_constructor_acceptsSingleMemberSet() public {
        bytes32[] memory single = new bytes32[](1);
        single[0] = _b32(address(proverA));
        EcoProver agg = new EcoProver(single);
        address[] memory members = agg.getMembers();
        assertEq(members.length, 1);
        assertEq(members[0], address(proverA));
    }

    function test_prove_alwaysReverts() public {
        vm.expectRevert(EcoProver.ProvingNotSupported.selector);
        aggregator.prove{value: 1 ether}(address(this), 1, "", "");
    }

    function test_getProofType() public view {
        assertEq(aggregator.getProofType(), "Aggregator");
    }

    function test_supportsInterface() public view {
        assertTrue(aggregator.supportsInterface(type(IProver).interfaceId));
        assertFalse(aggregator.supportsInterface(bytes4(0xdeadbeef)));
    }

    /// @dev version() is rewritten by semantic-release, so assert shape only
    function test_version() public view {
        string memory v = aggregator.version();
        assertGt(bytes(v).length, 0, "version is empty");
    }

    function test_provenIntents_returnsZeroWhenNoMemberHasProof() public view {
        IProver.ProofData memory proof = aggregator.provenIntents(
            keccak256("nothing")
        );
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, 0);
    }

    function test_provenIntents_returnsSingleMemberProof() public {
        proverB.addProvenIntent(HASH, address(0xBEEF), DESTINATION);

        IProver.ProofData memory proof = aggregator.provenIntents(HASH);
        assertEq(proof.claimant, address(0xBEEF));
        assertEq(proof.destination, DESTINATION);
    }

    function test_provenIntents_firstMemberWinsOnConflict() public {
        proverA.addProvenIntent(HASH, address(0xA11CE), DESTINATION);
        proverB.addProvenIntent(HASH, address(0xB0B), DESTINATION);

        IProver.ProofData memory proof = aggregator.provenIntents(HASH);
        assertEq(proof.claimant, address(0xA11CE));
    }

    function test_provenIntents_skipsCodelessMember() public {
        address codeless = address(0xDEAD);
        EcoProver agg = new EcoProver(_pair(codeless, address(proverB)));
        proverB.addProvenIntent(HASH, address(0xBEEF), DESTINATION);

        IProver.ProofData memory proof = agg.provenIntents(HASH);
        assertEq(proof.claimant, address(0xBEEF));
    }

    function test_provenIntents_skipsRevertingMember() public {
        RevertingProver bad = new RevertingProver();
        EcoProver agg = new EcoProver(_pair(address(bad), address(proverB)));
        proverB.addProvenIntent(HASH, address(0xBEEF), DESTINATION);

        IProver.ProofData memory proof = agg.provenIntents(HASH);
        assertEq(proof.claimant, address(0xBEEF));
    }

    function test_provenIntents_skipsCodelessAndRevertingTogether() public {
        RevertingProver bad = new RevertingProver();
        EcoProver agg = new EcoProver(
            _triple(address(0xDEAD), address(bad), address(proverB))
        );
        proverB.addProvenIntent(HASH, address(0xBEEF), DESTINATION);

        IProver.ProofData memory proof = agg.provenIntents(HASH);
        assertEq(proof.claimant, address(0xBEEF));
    }

    /// @dev Pins the Fix-2 hardening: a code-bearing member that returns
    ///      SUCCESS with the wrong returndata shape (not the 64-byte ProofData
    ///      encoding) must be treated as "no proof" and skipped, not revert
    ///      the whole call. A plain interface call would ABI-decode-revert in
    ///      THIS frame, outside any try/catch, permanently freezing both
    ///      withdraw and refund for every intent naming this aggregator.
    function test_provenIntents_skipsWrongShapeReturndataMember() public {
        MalformedProver bad = new MalformedProver();
        EcoProver agg = new EcoProver(_pair(address(bad), address(proverB)));
        proverB.addProvenIntent(HASH, address(0xBEEF), DESTINATION);

        IProver.ProofData memory proof = agg.provenIntents(HASH);
        assertEq(proof.claimant, address(0xBEEF));
    }

    /// @dev Pins the dirty-bits hardening: a code-bearing member that returns
    ///      exactly 64 bytes (the correct ProofData shape) but with non-zero
    ///      padding bits in the address/uint64 words must be treated as "no
    ///      proof" and skipped, not revert the whole call. Decoding this exact
    ///      payload directly to (address, uint64) would ABI-decode-revert in
    ///      THIS frame, outside any try/catch, permanently freezing both
    ///      withdraw and refund for every intent naming this aggregator.
    function test_provenIntents_skipsDirtyBitsReturndataMember() public {
        DirtyBitsProver bad = new DirtyBitsProver();
        EcoProver agg = new EcoProver(_pair(address(bad), address(proverB)));
        proverB.addProvenIntent(HASH, address(0xBEEF), DESTINATION);

        IProver.ProofData memory proof = agg.provenIntents(HASH);
        assertEq(proof.claimant, address(0xBEEF));
        assertEq(proof.destination, DESTINATION);
    }

    /// @dev Pins the Fix-1 hardening: a code-bearing member that returns
    ///      SUCCESS with a single EMPTY DYNAMIC value (bytes/string/array)
    ///      ABI-encodes to exactly 64 bytes — an offset head 0x20 followed by
    ///      a length word 0x00 — which passes both the size check and the
    ///      bit-range check. Without the destination-zero guard, the ABI
    ///      OFFSET WORD itself would surface as a fabricated non-zero
    ///      claimant (address(0x20)) with destination 0, for every
    ///      intentHash. This member sits at priority 0 and must be skipped,
    ///      with the honest proverB at priority 1 still winning.
    function test_provenIntents_skipsEmptyDynamicReturndataMember() public {
        EmptyDynamicProver bad = new EmptyDynamicProver();
        EcoProver agg = new EcoProver(_pair(address(bad), address(proverB)));
        proverB.addProvenIntent(HASH, address(0xBEEF), DESTINATION);

        IProver.ProofData memory proof = agg.provenIntents(HASH);
        assertEq(proof.claimant, address(0xBEEF));
        assertEq(proof.destination, DESTINATION);
    }

    function test_provenIntents_returnsZeroWhenAllMembersMisbehave() public {
        RevertingProver bad = new RevertingProver();
        EcoProver agg = new EcoProver(_pair(address(0xDEAD), address(bad)));

        IProver.ProofData memory proof = agg.provenIntents(HASH);
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, 0);
    }

    function test_provenIntents_preservesDestinationFromMember() public {
        proverA.addProvenIntent(HASH, address(0xA11CE), WRONG_DESTINATION);

        IProver.ProofData memory proof = aggregator.provenIntents(HASH);
        assertEq(proof.destination, WRONG_DESTINATION);
    }

    event ChallengeForwarded(bytes32 indexed intentHash);

    function _challengeHash(
        uint64 destination,
        bytes32 routeHash,
        bytes32 rewardHash
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(destination, routeHash, rewardHash));
    }

    function test_challenge_deletesMismatchedProofOnly() public {
        bytes32 routeHash = keccak256("route");
        bytes32 rewardHash = keccak256("reward");
        bytes32 intentHash = _challengeHash(DESTINATION, routeHash, rewardHash);

        // proverA lies about the destination, proverB is honest
        proverA.addProvenIntent(
            intentHash,
            address(0xA11CE),
            WRONG_DESTINATION
        );
        proverB.addProvenIntent(intentHash, address(0xB0B), DESTINATION);

        aggregator.challengeIntentProof(DESTINATION, routeHash, rewardHash);

        // The liar's entry is gone
        assertEq(proverA.provenIntents(intentHash).claimant, address(0));
        // The honest entry survives untouched
        assertEq(proverB.provenIntents(intentHash).claimant, address(0xB0B));
        assertEq(proverB.provenIntents(intentHash).destination, DESTINATION);
    }

    function test_challenge_afterForwardingAggregatorReturnsHonestProof()
        public
    {
        bytes32 routeHash = keccak256("route");
        bytes32 rewardHash = keccak256("reward");
        bytes32 intentHash = _challengeHash(DESTINATION, routeHash, rewardHash);

        proverA.addProvenIntent(
            intentHash,
            address(0xA11CE),
            WRONG_DESTINATION
        );
        proverB.addProvenIntent(intentHash, address(0xB0B), DESTINATION);

        assertEq(
            aggregator.provenIntents(intentHash).claimant,
            address(0xA11CE)
        );

        aggregator.challengeIntentProof(DESTINATION, routeHash, rewardHash);

        assertEq(aggregator.provenIntents(intentHash).claimant, address(0xB0B));
    }

    function test_challenge_toleratesRevertingAndCodelessMembers() public {
        RevertingProver bad = new RevertingProver();
        EcoProver agg = new EcoProver(
            _triple(address(0xDEAD), address(bad), address(proverB))
        );

        bytes32 routeHash = keccak256("route");
        bytes32 rewardHash = keccak256("reward");
        bytes32 intentHash = _challengeHash(DESTINATION, routeHash, rewardHash);
        proverB.addProvenIntent(intentHash, address(0xB0B), WRONG_DESTINATION);

        // Must not revert, and must still reach proverB
        agg.challengeIntentProof(DESTINATION, routeHash, rewardHash);

        assertEq(proverB.provenIntents(intentHash).claimant, address(0));
    }

    function test_challenge_emitsChallengeForwarded() public {
        bytes32 routeHash = keccak256("route");
        bytes32 rewardHash = keccak256("reward");
        bytes32 intentHash = _challengeHash(DESTINATION, routeHash, rewardHash);

        vm.expectEmit(true, false, false, false);
        emit ChallengeForwarded(intentHash);
        aggregator.challengeIntentProof(DESTINATION, routeHash, rewardHash);
    }
}
