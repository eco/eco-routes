// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {CCTPProver} from "../../contracts/prover/CCTPProver.sol";
import {MockMessageTransmitterV2} from "../../contracts/test/MockMessageTransmitterV2.sol";
import {IMessageBridgeProver} from "../../contracts/interfaces/IMessageBridgeProver.sol";
import {IProver} from "../../contracts/interfaces/IProver.sol";
import {CANCELLED_CLAIMANT, CANCELLED_CLAIMANT_BYTES32} from "../../contracts/types/Intent.sol";

contract RejectsEth {
    receive() external payable {
        revert("no");
    }
}

contract CCTPProverTest is BaseTest {
    uint32 internal constant BASE_DOMAIN = 6; // this chain in the tests
    uint32 internal constant ETH_DOMAIN = 0;
    uint32 internal constant ARB_DOMAIN = 3;
    uint32 internal constant SOLANA_DOMAIN = 5;
    uint64 internal constant ETH_CHAIN_ID = 1;
    uint64 internal constant ARB_CHAIN_ID = 42161;
    uint64 internal constant SOLANA_CHAIN_ID = 1399811149;
    uint16 internal constant SOLANA_MAX_PAIRS = 6; // estimate; Task 10 pins the G3 value

    bytes32 internal constant EVM_PEER =
        bytes32(uint256(uint160(0x1234567890123456789012345678901234567890)));
    // Synthetic 32-byte Solana program id (high bytes non-zero).
    bytes32 internal constant SOLANA_PEER =
        0x0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9;

    MockMessageTransmitterV2 internal transmitter;
    CCTPProver internal cctp;

    function setUp() public override {
        super.setUp();
        transmitter = new MockMessageTransmitterV2(BASE_DOMAIN);
        cctp = _deploy(_domains(), _caps());
    }

    // ---------- helpers ----------

    function _domains()
        internal
        pure
        returns (IMessageBridgeProver.Domain[] memory d)
    {
        d = new IMessageBridgeProver.Domain[](3);
        d[0] = IMessageBridgeProver.Domain({
            domain: ETH_DOMAIN,
            chainId: ETH_CHAIN_ID
        });
        d[1] = IMessageBridgeProver.Domain({
            domain: ARB_DOMAIN,
            chainId: ARB_CHAIN_ID
        });
        d[2] = IMessageBridgeProver.Domain({
            domain: SOLANA_DOMAIN,
            chainId: SOLANA_CHAIN_ID
        });
    }

    function _caps() internal pure returns (CCTPProver.MaxPairs[] memory c) {
        c = new CCTPProver.MaxPairs[](1);
        c[0] = CCTPProver.MaxPairs({
            domain: SOLANA_DOMAIN,
            maxPairs: SOLANA_MAX_PAIRS
        });
    }

    function _deploy(
        IMessageBridgeProver.Domain[] memory d,
        CCTPProver.MaxPairs[] memory c
    ) internal returns (CCTPProver) {
        bytes32[] memory provers = new bytes32[](2);
        provers[0] = EVM_PEER;
        provers[1] = SOLANA_PEER;
        return
            new CCTPProver(
                address(portal),
                address(transmitter),
                provers,
                d,
                c
            );
    }

    function _proofs(uint256 n) internal view returns (bytes memory out) {
        out = abi.encodePacked(uint64(block.chainid));
        for (uint256 i = 0; i < n; i++) {
            out = abi.encodePacked(
                out,
                keccak256(abi.encode("intent", i)),
                bytes32(uint256(uint160(address(uint160(0xC1A1 + i)))))
            );
        }
    }

    function _prove(
        uint64 domain,
        bytes memory proofs,
        uint256 value
    ) internal {
        vm.deal(address(portal), value);
        vm.prank(address(portal));
        cctp.prove{value: value}(
            address(portal),
            domain,
            proofs,
            abi.encode(EVM_PEER)
        );
    }

    // ---------- constructor ----------

    function test_constructor_readsLocalDomainAndStoresConfig() public view {
        assertEq(cctp.TRANSMITTER(), address(transmitter));
        assertEq(cctp.LOCAL_DOMAIN(), BASE_DOMAIN);
        assertEq(cctp.MIN_FINALITY_THRESHOLD(), 1000);
        assertEq(cctp.getProofType(), "CCTP");
        assertEq(cctp.PORTAL(), address(portal));
        assertTrue(cctp.isWhitelisted(EVM_PEER));
        assertTrue(cctp.isWhitelisted(SOLANA_PEER));
        assertEq(cctp.maxPairsByDomain(SOLANA_DOMAIN), SOLANA_MAX_PAIRS);
        assertEq(cctp.maxPairsByDomain(ARB_DOMAIN), 0);
    }

    function test_constructor_registersDomainZero() public view {
        assertEq(cctp.chainIdByDomain(ETH_DOMAIN), ETH_CHAIN_ID);
        assertEq(cctp.chainIdByDomain(ARB_DOMAIN), ARB_CHAIN_ID);
        assertEq(cctp.chainIdByDomain(SOLANA_DOMAIN), SOLANA_CHAIN_ID);
    }

    function test_constructor_emitsDomainRegisteredForDomainZero() public {
        vm.expectEmit(true, true, false, false);
        emit IMessageBridgeProver.DomainRegistered(ETH_DOMAIN, ETH_CHAIN_ID);
        _deploy(_domains(), _caps());
    }

    function test_constructor_rejectsZeroTransmitter() public {
        vm.expectRevert(CCTPProver.TransmitterCannotBeZeroAddress.selector);
        new CCTPProver(
            address(portal),
            address(0),
            new bytes32[](0),
            _domains(),
            _caps()
        );
    }

    function test_constructor_rejectsDuplicateDomainZero() public {
        IMessageBridgeProver.Domain[]
            memory d = new IMessageBridgeProver.Domain[](2);
        d[0] = IMessageBridgeProver.Domain({domain: 0, chainId: 1});
        d[1] = IMessageBridgeProver.Domain({domain: 0, chainId: 2});
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.InvalidDomainConfig.selector,
                uint64(0),
                uint64(2)
            )
        );
        _deploy(d, _caps());
    }

    function test_constructor_rejectsDuplicateChainId() public {
        IMessageBridgeProver.Domain[]
            memory d = new IMessageBridgeProver.Domain[](2);
        d[0] = IMessageBridgeProver.Domain({domain: 2, chainId: 10});
        d[1] = IMessageBridgeProver.Domain({domain: 3, chainId: 10});
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.InvalidDomainConfig.selector,
                uint64(3),
                uint64(10)
            )
        );
        _deploy(d, _caps());
    }

    function test_constructor_rejectsZeroChainId() public {
        IMessageBridgeProver.Domain[]
            memory d = new IMessageBridgeProver.Domain[](1);
        d[0] = IMessageBridgeProver.Domain({domain: 2, chainId: 0});
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.InvalidDomainConfig.selector,
                uint64(2),
                uint64(0)
            )
        );
        _deploy(d, _caps());
    }

    function test_constructor_rejectsDomainAboveUint32() public {
        IMessageBridgeProver.Domain[]
            memory d = new IMessageBridgeProver.Domain[](1);
        uint64 tooBig = uint64(type(uint32).max) + 1;
        d[0] = IMessageBridgeProver.Domain({domain: tooBig, chainId: 10});
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.InvalidDomainConfig.selector,
                tooBig,
                uint64(10)
            )
        );
        _deploy(d, _caps());
    }

    function test_constructor_rejectsLocalDomain() public {
        IMessageBridgeProver.Domain[]
            memory d = new IMessageBridgeProver.Domain[](1);
        d[0] = IMessageBridgeProver.Domain({
            domain: BASE_DOMAIN,
            chainId: 8453
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.InvalidDomainConfig.selector,
                uint64(BASE_DOMAIN),
                uint64(8453)
            )
        );
        _deploy(d, _caps());
    }

    function test_constructor_rejectsZeroMaxPairs() public {
        CCTPProver.MaxPairs[] memory c = new CCTPProver.MaxPairs[](1);
        c[0] = CCTPProver.MaxPairs({domain: SOLANA_DOMAIN, maxPairs: 0});
        vm.expectRevert(
            abi.encodeWithSelector(
                CCTPProver.InvalidMaxPairsConfig.selector,
                SOLANA_DOMAIN,
                uint16(0)
            )
        );
        _deploy(_domains(), c);
    }

    function test_constructor_rejectsDuplicateMaxPairsDomain() public {
        CCTPProver.MaxPairs[] memory c = new CCTPProver.MaxPairs[](2);
        c[0] = CCTPProver.MaxPairs({domain: SOLANA_DOMAIN, maxPairs: 7});
        c[1] = CCTPProver.MaxPairs({domain: SOLANA_DOMAIN, maxPairs: 6});
        vm.expectRevert(
            abi.encodeWithSelector(
                CCTPProver.InvalidMaxPairsConfig.selector,
                SOLANA_DOMAIN,
                uint16(6)
            )
        );
        _deploy(_domains(), c);
    }

    // ---------- send ----------

    function test_prove_sendsAlwaysFastWithOpenCaller() public {
        bytes memory proofs = _proofs(2);
        _prove(ARB_DOMAIN, proofs, 0);

        assertEq(transmitter.sendCount(), 1);
        assertEq(transmitter.lastDestinationDomain(), ARB_DOMAIN);
        assertEq(transmitter.lastRecipient(), EVM_PEER);
        assertEq(transmitter.lastDestinationCaller(), bytes32(0));
        assertEq(transmitter.lastMinFinalityThreshold(), 1000);
        assertEq(transmitter.lastMessageBody(), proofs);
        assertEq(transmitter.lastSender(), address(cctp));
    }

    function test_prove_toEthereumDomainZero() public {
        _prove(ETH_DOMAIN, _proofs(1), 0);
        assertEq(transmitter.lastDestinationDomain(), ETH_DOMAIN);
    }

    function test_fetchFee_isZero() public view {
        assertEq(
            cctp.fetchFee(ARB_DOMAIN, _proofs(1), abi.encode(EVM_PEER)),
            0
        );
    }

    function test_prove_refundsAllValueToSender() public {
        address payer = makeAddr("payer");
        vm.deal(address(portal), 1 ether);
        vm.prank(address(portal));
        cctp.prove{value: 1 ether}(
            payer,
            ARB_DOMAIN,
            _proofs(1),
            abi.encode(EVM_PEER)
        );
        assertEq(payer.balance, 1 ether);
        assertEq(address(cctp).balance, 0);
    }

    function test_prove_revertsWhenRefundRecipientRejectsEth() public {
        RejectsEth sink = new RejectsEth();
        vm.deal(address(portal), 1 ether);
        vm.prank(address(portal));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.RefundFailed.selector,
                address(sink),
                1 ether
            )
        );
        cctp.prove{value: 1 ether}(
            address(sink),
            ARB_DOMAIN,
            _proofs(1),
            abi.encode(EVM_PEER)
        );
    }

    function test_prove_onlyPortal() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.UnauthorizedSender.selector,
                address(portal),
                address(this)
            )
        );
        cctp.prove(address(this), ARB_DOMAIN, _proofs(1), abi.encode(EVM_PEER));
    }

    function test_prove_rejectsDomainAboveUint32() public {
        uint64 tooBig = uint64(type(uint32).max) + 1;
        vm.prank(address(portal));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.DomainIdTooLarge.selector,
                tooBig
            )
        );
        cctp.prove(address(portal), tooBig, _proofs(1), abi.encode(EVM_PEER));
    }

    function test_prove_rejectsLocalDomain() public {
        vm.prank(address(portal));
        vm.expectRevert(
            abi.encodeWithSelector(
                CCTPProver.InvalidDestinationDomain.selector,
                uint64(BASE_DOMAIN)
            )
        );
        cctp.prove(
            address(portal),
            BASE_DOMAIN,
            _proofs(1),
            abi.encode(EVM_PEER)
        );
    }

    function test_prove_rejectsZeroSourceChainProver() public {
        vm.prank(address(portal));
        vm.expectRevert(CCTPProver.SourceChainProverCannotBeZero.selector);
        cctp.prove(
            address(portal),
            ARB_DOMAIN,
            _proofs(1),
            abi.encode(bytes32(0))
        );
    }

    function test_prove_rejectsMalformedProofLength() public {
        bytes memory bad = abi.encodePacked(_proofs(1), bytes1(0x00));
        vm.prank(address(portal));
        vm.expectRevert(
            abi.encodeWithSelector(
                CCTPProver.InvalidEncodedProofsLength.selector,
                bad.length
            )
        );
        cctp.prove(address(portal), ARB_DOMAIN, bad, abi.encode(EVM_PEER));
    }

    function test_prove_solanaLaneAcceptsExactlyMaxPairs() public {
        _prove(SOLANA_DOMAIN, _proofs(SOLANA_MAX_PAIRS), 0);
        assertEq(transmitter.lastRecipient(), EVM_PEER);
    }

    function test_prove_solanaLaneRejectsMaxPairsPlusOne() public {
        bytes memory proofs = _proofs(uint256(SOLANA_MAX_PAIRS) + 1);
        vm.prank(address(portal));
        vm.expectRevert(
            abi.encodeWithSelector(
                CCTPProver.TooManyPairs.selector,
                SOLANA_DOMAIN,
                uint256(SOLANA_MAX_PAIRS) + 1,
                uint256(SOLANA_MAX_PAIRS)
            )
        );
        cctp.prove(
            address(portal),
            SOLANA_DOMAIN,
            proofs,
            abi.encode(EVM_PEER)
        );
    }

    function test_prove_uncappedLaneAccepts127Pairs() public {
        bytes memory proofs = _proofs(127); // 8 + 127*64 = 8136 <= 8192
        _prove(ARB_DOMAIN, proofs, 0);
        assertEq(transmitter.lastMessageBody().length, 8136);
    }

    // ---------- receive ----------

    function _body(
        uint64 chainId,
        bytes32 intentHash,
        bytes32 claimant
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(chainId, intentHash, claimant);
    }

    function _claimant(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function test_receive_fastFromArbitrumRecords() public {
        bytes32 h = keccak256("arb-intent");
        address solver = makeAddr("solver");
        transmitter.deliver(
            address(cctp),
            ARB_DOMAIN,
            EVM_PEER,
            1000,
            _body(ARB_CHAIN_ID, h, _claimant(solver))
        );

        IProver.ProofData memory p = cctp.provenIntents(h);
        assertEq(p.claimant, solver);
        assertEq(p.destination, ARB_CHAIN_ID);
    }

    function test_receive_finalizedFromArbitrumRecords() public {
        bytes32 h = keccak256("arb-final");
        address solver = makeAddr("solver");
        transmitter.deliver(
            address(cctp),
            ARB_DOMAIN,
            EVM_PEER,
            2000,
            _body(ARB_CHAIN_ID, h, _claimant(solver))
        );
        assertEq(cctp.provenIntents(h).claimant, solver);
    }

    function test_receive_ethereumDomainZeroRecords() public {
        bytes32 h = keccak256("eth-intent");
        address solver = makeAddr("solver");
        transmitter.deliver(
            address(cctp),
            ETH_DOMAIN,
            EVM_PEER,
            1000,
            _body(ETH_CHAIN_ID, h, _claimant(solver))
        );

        IProver.ProofData memory p = cctp.provenIntents(h);
        assertEq(p.claimant, solver);
        assertEq(p.destination, ETH_CHAIN_ID);
    }

    function test_receive_solanaProgramIdSenderRecords() public {
        bytes32 h = keccak256("sol-intent");
        address solver = makeAddr("solver");
        transmitter.deliver(
            address(cctp),
            SOLANA_DOMAIN,
            SOLANA_PEER,
            1000,
            _body(SOLANA_CHAIN_ID, h, _claimant(solver))
        );
        assertEq(cctp.provenIntents(h).destination, SOLANA_CHAIN_ID);
    }

    function test_receive_returnsTrueOnBothHandlers() public {
        vm.startPrank(address(transmitter));
        assertTrue(
            cctp.handleReceiveUnfinalizedMessage(
                ARB_DOMAIN,
                EVM_PEER,
                1000,
                _body(ARB_CHAIN_ID, keccak256("a"), _claimant(address(1)))
            )
        );
        assertTrue(
            cctp.handleReceiveFinalizedMessage(
                ARB_DOMAIN,
                EVM_PEER,
                2000,
                _body(ARB_CHAIN_ID, keccak256("b"), _claimant(address(1)))
            )
        );
        vm.stopPrank();
    }

    function test_receive_onlyTransmitter() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.UnauthorizedSender.selector,
                address(transmitter),
                address(this)
            )
        );
        cctp.handleReceiveFinalizedMessage(
            ARB_DOMAIN,
            EVM_PEER,
            2000,
            _body(ARB_CHAIN_ID, keccak256("x"), _claimant(address(1)))
        );
    }

    function test_receive_rejectsNonWhitelistedSender() public {
        bytes32 stranger = _claimant(makeAddr("stranger"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.UnauthorizedIncomingProof.selector,
                stranger
            )
        );
        transmitter.deliver(
            address(cctp),
            ARB_DOMAIN,
            stranger,
            1000,
            _body(ARB_CHAIN_ID, keccak256("x"), _claimant(address(1)))
        );
    }

    function test_receive_rejectsUnregisteredDomain() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.UnregisteredDomain.selector,
                uint64(2)
            )
        );
        transmitter.deliver(
            address(cctp),
            2,
            EVM_PEER,
            1000,
            _body(10, keccak256("x"), _claimant(address(1)))
        );
    }

    /// Review Focus 4: same CREATE3 address on every chain, so a whitelisted
    /// sender from one domain must not be able to claim another chain.
    function test_receive_rejectsChainIdNotMatchingAttestedDomain() public {
        bytes32 h = keccak256("spoof");
        vm.expectRevert(
            abi.encodeWithSelector(
                IMessageBridgeProver.ChainIdMismatch.selector,
                uint64(ETH_DOMAIN),
                ETH_CHAIN_ID,
                ARB_CHAIN_ID
            )
        );
        transmitter.deliver(
            address(cctp),
            ETH_DOMAIN,
            EVM_PEER,
            1000,
            _body(ARB_CHAIN_ID, h, _claimant(address(1)))
        );
        assertEq(cctp.provenIntents(h).claimant, address(0));
    }

    function test_receive_firstProofWins() public {
        bytes32 h = keccak256("conflict");
        address first = makeAddr("first");
        address second = makeAddr("second");
        transmitter.deliver(
            address(cctp),
            ARB_DOMAIN,
            EVM_PEER,
            1000,
            _body(ARB_CHAIN_ID, h, _claimant(first))
        );
        transmitter.deliver(
            address(cctp),
            ARB_DOMAIN,
            EVM_PEER,
            1000,
            _body(ARB_CHAIN_ID, h, _claimant(second))
        );
        assertEq(cctp.provenIntents(h).claimant, first);
    }

    function test_receive_recordsCancelledClaimant() public {
        bytes32 h = keccak256("cancelled");
        transmitter.deliver(
            address(cctp),
            ARB_DOMAIN,
            EVM_PEER,
            1000,
            _body(ARB_CHAIN_ID, h, CANCELLED_CLAIMANT_BYTES32)
        );
        assertEq(cctp.provenIntents(h).claimant, CANCELLED_CLAIMANT);
    }

    function test_receive_multiplePairs() public {
        bytes32 h1 = keccak256("m1");
        bytes32 h2 = keccak256("m2");
        address a = makeAddr("a");
        address b = makeAddr("b");
        bytes memory body = abi.encodePacked(
            ARB_CHAIN_ID,
            h1,
            _claimant(a),
            h2,
            _claimant(b)
        );
        transmitter.deliver(address(cctp), ARB_DOMAIN, EVM_PEER, 1000, body);
        assertEq(cctp.provenIntents(h1).claimant, a);
        assertEq(cctp.provenIntents(h2).claimant, b);
    }
}
