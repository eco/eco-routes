// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Portal} from "../../contracts/Portal.sol";
import {CCTPProver} from "../../contracts/prover/CCTPProver.sol";
import {IMessageTransmitterV2} from "../../contracts/interfaces/cctp/IMessageTransmitterV2.sol";
import {IMessageBridgeProver} from "../../contracts/interfaces/IMessageBridgeProver.sol";

/// @dev Run with CCTP_FORK_RPC_URL set to a Base mainnet RPC; skipped otherwise.
contract CCTPProverForkTest is Test {
    address internal constant TRANSMITTER =
        0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    uint32 internal constant BASE_DOMAIN = 6;
    uint32 internal constant ARB_DOMAIN = 3;
    uint64 internal constant ARB_CHAIN_ID = 42161;
    bytes32 internal constant PEER =
        bytes32(uint256(uint160(0x1234567890123456789012345678901234567890)));

    uint256 internal attesterKey;
    CCTPProver internal cctp;
    bool internal skipFork;

    function setUp() public {
        string memory rpc = vm.envOr("CCTP_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            skipFork = true;
            return;
        }
        vm.createSelectFork(rpc);

        attesterKey = uint256(keccak256("cctp-fork-test-attester"));
        address attester = vm.addr(attesterKey);
        (, bytes memory ret) = TRANSMITTER.staticcall(
            abi.encodeWithSignature("attesterManager()")
        );
        address manager = abi.decode(ret, (address));
        vm.startPrank(manager);
        (bool ok1, ) = TRANSMITTER.call(
            abi.encodeWithSignature("enableAttester(address)", attester)
        );
        (bool ok2, ) = TRANSMITTER.call(
            abi.encodeWithSignature("setSignatureThreshold(uint256)", 1)
        );
        vm.stopPrank();
        require(ok1 && ok2, "attester setup failed");

        Portal portal = new Portal(address(0));
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
            TRANSMITTER,
            provers,
            d,
            new CCTPProver.MaxPairs[](0)
        );
    }

    /// CCTP V2 header: version(4) srcDomain(4) dstDomain(4) nonce(32) sender(32)
    /// recipient(32) destinationCaller(32) minFinality(4) finalityExecuted(4) body
    function _message(
        bytes32 nonce,
        uint32 finality,
        bytes memory body
    ) internal view returns (bytes memory) {
        return
            abi.encodePacked(
                uint32(1),
                ARB_DOMAIN,
                BASE_DOMAIN,
                nonce,
                PEER,
                bytes32(uint256(uint160(address(cctp)))),
                bytes32(0),
                uint32(1000),
                finality,
                body
            );
    }

    function _attest(
        bytes memory message
    ) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            attesterKey,
            keccak256(message)
        );
        return abi.encodePacked(r, s, v);
    }

    function _body(uint256 n) internal pure returns (bytes memory out) {
        out = abi.encodePacked(ARB_CHAIN_ID);
        for (uint256 i = 0; i < n; i++) {
            out = abi.encodePacked(
                out,
                keccak256(abi.encode("fork", i)),
                bytes32(uint256(uint160(0xC1A1 + i)))
            );
        }
    }

    function test_fork_receiveMessageFastRecordsAndConsumesNonce() public {
        if (skipFork) return;
        bytes32 nonce = keccak256("fork-nonce-1");
        bytes memory message = _message(nonce, 1000, _body(1));

        uint256 g = gasleft();
        assertTrue(
            IMessageTransmitterV2(TRANSMITTER).receiveMessage(
                message,
                _attest(message)
            )
        );
        uint256 used = g - gasleft();
        console.log("receiveMessage gas, 1 pair:", used);
        assertLt(used, 160_000);

        assertEq(
            cctp
                .provenIntents(keccak256(abi.encode("fork", uint256(0))))
                .destination,
            ARB_CHAIN_ID
        );

        vm.expectRevert(bytes("Nonce already used"));
        IMessageTransmitterV2(TRANSMITTER).receiveMessage(
            message,
            _attest(message)
        );
    }

    function test_fork_receiveMessageFinalizedRecords() public {
        if (skipFork) return;
        bytes memory message = _message(
            keccak256("fork-nonce-2"),
            2000,
            _body(1)
        );
        assertTrue(
            IMessageTransmitterV2(TRANSMITTER).receiveMessage(
                message,
                _attest(message)
            )
        );
    }

    function test_fork_gasPerExtraPair() public {
        if (skipFork) return;
        bytes memory m1 = _message(keccak256("g1"), 1000, _body(1));
        bytes memory m2 = _message(keccak256("g2"), 1000, _body(11));
        uint256 g = gasleft();
        IMessageTransmitterV2(TRANSMITTER).receiveMessage(m1, _attest(m1));
        uint256 one = g - gasleft();
        g = gasleft();
        IMessageTransmitterV2(TRANSMITTER).receiveMessage(m2, _attest(m2));
        uint256 eleven = g - gasleft();
        console.log("per extra pair:", (eleven - one) / 10);
        assertLt((eleven - one) / 10, 35_000);
    }
}
