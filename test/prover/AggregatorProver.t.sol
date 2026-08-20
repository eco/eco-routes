// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {AggregatorProver} from "../../contracts/prover/AggregatorProver.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {Portal} from "../../contracts/Portal.sol";
import {TestProver} from "../../contracts/test/TestProver.sol";
import {RevertingProver} from "../../contracts/test/RevertingProver.sol";
import {Whitelist} from "../../contracts/libs/Whitelist.sol";

contract AggregatorProverTest is Test {
    Portal internal portal;
    TestProver internal proverA;
    TestProver internal proverB;
    AggregatorProver internal aggregator;

    bytes32 internal constant HASH = keccak256("intent");
    uint64 internal constant DESTINATION = 8453;
    uint64 internal constant WRONG_DESTINATION = 999;

    event MemberRegistered(address indexed member, uint256 indexed priority);

    function setUp() public {
        portal = new Portal(address(0));
        proverA = new TestProver(address(portal));
        proverB = new TestProver(address(portal));
        aggregator = new AggregatorProver(
            _pair(address(proverA), address(proverB))
        );

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
        new AggregatorProver(_pair(address(proverA), address(proverB)));
    }

    function test_constructor_revertsOnEmptySet() public {
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert(
            abi.encodeWithSelector(
                AggregatorProver.InvalidMemberSet.selector,
                0,
                8
            )
        );
        new AggregatorProver(empty);
    }

    function test_constructor_revertsOnOversizedSet() public {
        bytes32[] memory nine = new bytes32[](9);
        for (uint256 i = 0; i < 9; ++i) {
            nine[i] = bytes32(uint256(i + 1));
        }
        vm.expectRevert(
            abi.encodeWithSelector(
                AggregatorProver.InvalidMemberSet.selector,
                9,
                8
            )
        );
        new AggregatorProver(nine);
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
        new AggregatorProver(twentyOne);
    }

    function test_constructor_revertsOnZeroMember() public {
        bytes32[] memory members = _pair(address(proverA), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                AggregatorProver.InvalidMember.selector,
                bytes32(0)
            )
        );
        new AggregatorProver(members);
    }

    function test_constructor_revertsOnNonEvmMember() public {
        bytes32 nonEvm = bytes32(type(uint256).max);
        bytes32[] memory members = new bytes32[](2);
        members[0] = _b32(address(proverA));
        members[1] = nonEvm;
        vm.expectRevert(
            abi.encodeWithSelector(
                AggregatorProver.InvalidMember.selector,
                nonEvm
            )
        );
        new AggregatorProver(members);
    }

    function test_constructor_revertsOnDuplicateMember() public {
        bytes32[] memory members = _pair(address(proverA), address(proverA));
        vm.expectRevert(
            abi.encodeWithSelector(
                AggregatorProver.DuplicateMember.selector,
                _b32(address(proverA))
            )
        );
        new AggregatorProver(members);
    }

    function test_constructor_acceptsMaxMembersSet() public {
        bytes32[] memory eight = new bytes32[](8);
        for (uint256 i = 0; i < 8; ++i) {
            eight[i] = bytes32(uint256(i + 1));
        }
        AggregatorProver agg = new AggregatorProver(eight);
        address[] memory members = agg.getMembers();
        assertEq(members.length, 8);
        for (uint256 i = 0; i < 8; ++i) {
            assertEq(members[i], address(uint160(i + 1)));
        }
    }

    function test_constructor_acceptsSingleMemberSet() public {
        bytes32[] memory single = new bytes32[](1);
        single[0] = _b32(address(proverA));
        AggregatorProver agg = new AggregatorProver(single);
        address[] memory members = agg.getMembers();
        assertEq(members.length, 1);
        assertEq(members[0], address(proverA));
    }

    function test_prove_alwaysReverts() public {
        vm.expectRevert(AggregatorProver.ProvingNotSupported.selector);
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
        AggregatorProver agg = new AggregatorProver(
            _pair(codeless, address(proverB))
        );
        proverB.addProvenIntent(HASH, address(0xBEEF), DESTINATION);

        IProver.ProofData memory proof = agg.provenIntents(HASH);
        assertEq(proof.claimant, address(0xBEEF));
    }

    function test_provenIntents_skipsRevertingMember() public {
        RevertingProver bad = new RevertingProver();
        AggregatorProver agg = new AggregatorProver(
            _pair(address(bad), address(proverB))
        );
        proverB.addProvenIntent(HASH, address(0xBEEF), DESTINATION);

        IProver.ProofData memory proof = agg.provenIntents(HASH);
        assertEq(proof.claimant, address(0xBEEF));
    }

    function test_provenIntents_skipsCodelessAndRevertingTogether() public {
        RevertingProver bad = new RevertingProver();
        AggregatorProver agg = new AggregatorProver(
            _triple(address(0xDEAD), address(bad), address(proverB))
        );
        proverB.addProvenIntent(HASH, address(0xBEEF), DESTINATION);

        IProver.ProofData memory proof = agg.provenIntents(HASH);
        assertEq(proof.claimant, address(0xBEEF));
    }

    function test_provenIntents_returnsZeroWhenAllMembersMisbehave() public {
        RevertingProver bad = new RevertingProver();
        AggregatorProver agg = new AggregatorProver(
            _pair(address(0xDEAD), address(bad))
        );

        IProver.ProofData memory proof = agg.provenIntents(HASH);
        assertEq(proof.claimant, address(0));
        assertEq(proof.destination, 0);
    }

    function test_provenIntents_preservesDestinationFromMember() public {
        proverA.addProvenIntent(HASH, address(0xA11CE), WRONG_DESTINATION);

        IProver.ProofData memory proof = aggregator.provenIntents(HASH);
        assertEq(proof.destination, WRONG_DESTINATION);
    }
}
