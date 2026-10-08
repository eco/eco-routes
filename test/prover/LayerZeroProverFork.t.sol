// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LayerZeroProver} from "../../contracts/prover/LayerZeroProver.sol";
import {ILayerZeroEndpointV2} from "../../contracts/interfaces/layerzero/ILayerZeroEndpointV2.sol";
import {IMessageBridgeProver} from "../../contracts/interfaces/IMessageBridgeProver.sol";

/// @dev Read surface of the real EndpointV2 and ULN302 used to check what the
///      constructor stored
interface ILayerZeroReadback {
    function getSendLibrary(
        address oapp,
        uint32 eid
    ) external view returns (address);

    function getReceiveLibrary(
        address oapp,
        uint32 eid
    ) external view returns (address lib, bool isDefault);

    function delegates(address oapp) external view returns (address);

    /// @dev ULN302: the stored (not default-merged) ULN config
    function getAppUlnConfig(
        address oapp,
        uint32 eid
    ) external view returns (LayerZeroProver.UlnConfig memory);

    /// @dev SendUln302: the stored executor config
    function executorConfigs(
        address oapp,
        uint32 eid
    ) external view returns (uint32 maxMessageSize, address executor);
}

/**
 * @title LayerZeroProverForkTest
 * @notice Deploys LayerZeroProver against Base mainnet's real EndpointV2 and
 *         ULN302 with the PAR-503 policy (23 remotes, 3-of-3 required DVNs) and
 *         reads every pathway back, Solana's smaller message cap included.
 * @dev Skipped unless LZ_FORK_RPC_URL points at a Base mainnet RPC. Addresses
 *      and confirmations come from eco-routes-deployer config/layerzero.json.
 */
contract LayerZeroProverForkTest is Test {
    address constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant SEND_ULN = 0xB5320B0B3a13cC860893E2Bd79FCd7e13484Dda2;
    address constant RECEIVE_ULN = 0xc70AB6f32772f59fBfc23889Caf4Ba3376C84bAf;
    address constant EXECUTOR = 0x2CCA08ae69E0C44b18a57Ab2A87644234dAebaE4;
    uint64 constant BASE_CONFIRMATIONS = 10;
    uint32 constant MAX_MESSAGE_SIZE = 10_000;
    /// @dev 8-byte chain-ID header + 6 (intentHash, claimant) pairs: the most
    ///      the LayerZero executor can deliver to the eco-routes-svm
    ///      layerzero_prover in one Solana transaction (7 measured 1227 bytes
    ///      against its 1220-byte limit on devnet)
    uint32 constant SOLANA_MAX_MESSAGE_SIZE = 392;
    uint32 constant SOLANA_EID = 30168;

    IMessageBridgeProver.Domain[] internal domains;
    uint64[] internal receiveConfirmations;
    uint32[] internal maxMessageSizes;

    function _remote(
        uint64 eid,
        uint64 chainId,
        uint64 confirmations
    ) internal {
        _remote(eid, chainId, confirmations, MAX_MESSAGE_SIZE);
    }

    function _remote(
        uint64 eid,
        uint64 chainId,
        uint64 confirmations,
        uint32 maxMessageSize
    ) internal {
        domains.push(IMessageBridgeProver.Domain(eid, chainId));
        receiveConfirmations.push(confirmations);
        maxMessageSizes.push(maxMessageSize);
    }

    function _forkOrSkip() internal returns (bool) {
        string memory rpc = vm.envOr("LZ_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 8453, "LZ_FORK_RPC_URL must be Base mainnet");

        _remote(30101, 1, 32); // Ethereum
        _remote(30111, 10, 20); // Optimism
        _remote(30110, 42161, 20); // Arbitrum
        _remote(30109, 137, 512); // Polygon
        _remote(30102, 56, 20); // BSC
        _remote(30320, 130, 20); // Unichain
        _remote(30332, 146, 20); // Sonic
        _remote(30125, 42220, 5); // Celo
        _remote(30319, 480, 20); // World Chain
        _remote(30339, 57073, 20); // Ink
        _remote(30383, 9745, 5); // Plasma
        _remote(30367, 999, 1); // HyperEVM
        _remote(30417, 5042, 5); // Arc
        _remote(30390, 143, 4); // Monad
        _remote(30416, 4663, 5); // Robinhood
        _remote(30420, 728126428, 19); // Tron
        _remote(SOLANA_EID, 1399811149, 32, SOLANA_MAX_MESSAGE_SIZE); // Solana
        _remote(30106, 43114, 20); // Avalanche (planned)
        _remote(30181, 5000, 20); // Mantle (planned)
        _remote(30150, 8217, 20); // Kaia (planned)
        _remote(30183, 59144, 20); // Linea (planned)
        _remote(30280, 1329, 20); // Sei (planned)
        _remote(30145, 100, 20); // Gnosis (planned)
        return true;
    }

    function _dvns() internal pure returns (address[] memory dvns) {
        // Strictly ascending: Canary, LayerZero Labs, Horizen.
        dvns = new address[](3);
        dvns[0] = 0x554833698Ae0FB22ECC90B01222903fD62CA4B47;
        dvns[1] = 0x9e059a54699a285714207b43B055483E78FAac25;
        dvns[2] = 0xa7b5189bcA84Cd304D8553977c7C614329750d99;
    }

    function _deploy() internal returns (LayerZeroProver prover, uint256 gas) {
        bytes32[] memory provers = new bytes32[](1);
        provers[0] = bytes32(uint256(0xbeef));
        LayerZeroProver.LayerZeroConfig memory config = LayerZeroProver
            .LayerZeroConfig({
                sendLibrary: SEND_ULN,
                receiveLibrary: RECEIVE_ULN,
                executor: EXECUTOR,
                maxMessageSizes: maxMessageSizes,
                requiredDVNs: _dvns(),
                sendConfirmations: BASE_CONFIRMATIONS,
                receiveConfirmations: receiveConfirmations
            });
        uint256 before = gasleft();
        prover = new LayerZeroProver(
            ENDPOINT,
            makeAddr("portal"),
            provers,
            200_000,
            domains,
            config
        );
        gas = before - gasleft();
    }

    function _assertUln(
        LayerZeroProver.UlnConfig memory uln,
        uint64 confirmations
    ) internal pure {
        address[] memory dvns = _dvns();
        assertEq(uln.confirmations, confirmations);
        assertEq(uln.requiredDVNCount, dvns.length);
        assertEq(uln.optionalDVNCount, type(uint8).max, "optional must be NIL");
        assertEq(uln.optionalDVNThreshold, 0);
        assertEq(uln.requiredDVNs, dvns);
        assertEq(uln.optionalDVNs.length, 0);
    }

    function test_fork_pinsEveryPathwayOnRealEndpoint() public {
        if (!_forkOrSkip()) return;
        (LayerZeroProver prover, uint256 gas) = _deploy();
        emit log_named_uint("deploy gas, 23 remotes", gas);

        ILayerZeroReadback endpoint = ILayerZeroReadback(ENDPOINT);
        for (uint256 i = 0; i < domains.length; i++) {
            uint32 eid = uint32(domains[i].domain);
            assertEq(endpoint.getSendLibrary(address(prover), eid), SEND_ULN);
            (address lib, bool isDefault) = endpoint.getReceiveLibrary(
                address(prover),
                eid
            );
            assertEq(lib, RECEIVE_ULN);
            assertFalse(isDefault, "receive library must be pinned");

            (uint32 maxMessageSize, address executor) = ILayerZeroReadback(
                SEND_ULN
            ).executorConfigs(address(prover), eid);
            assertEq(maxMessageSize, maxMessageSizes[i]);
            assertEq(executor, EXECUTOR);
            _assertUln(
                ILayerZeroReadback(SEND_ULN).getAppUlnConfig(
                    address(prover),
                    eid
                ),
                BASE_CONFIRMATIONS
            );
            _assertUln(
                ILayerZeroReadback(RECEIVE_ULN).getAppUlnConfig(
                    address(prover),
                    eid
                ),
                receiveConfirmations[i]
            );
        }
        // Sei's 12.5M block gas limit is the tightest of the rollout's EVM chains.
        assertLt(gas, 12_500_000, "deploy must fit Sei's block");
    }

    function test_fork_nobodyCanReconfigure() public {
        if (!_forkOrSkip()) return;
        (LayerZeroProver prover, ) = _deploy();
        assertEq(
            ILayerZeroReadback(ENDPOINT).delegates(address(prover)),
            address(prover)
        );

        ILayerZeroEndpointV2.SetConfigParam[]
            memory none = new ILayerZeroEndpointV2.SetConfigParam[](0);
        // The deployer, an outsider and address(0) (an unset delegate would
        // have matched it) are all refused.
        address[3] memory callers = [
            address(this),
            makeAddr("attacker"),
            address(0)
        ];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert();
            ILayerZeroEndpointV2(ENDPOINT).setConfig(
                address(prover),
                SEND_ULN,
                none
            );
        }
    }

    /// @dev Proofs as Inbox._prove encodes them: 8-byte chain ID + n pairs
    function _proofs(uint256 n) internal pure returns (bytes memory proofs) {
        proofs = abi.encodePacked(uint64(8453));
        for (uint256 i = 0; i < n; i++) {
            proofs = abi.encodePacked(
                proofs,
                keccak256(abi.encode(i)),
                bytes32(uint256(0xc1a1))
            );
        }
    }

    /// @dev The real SendUln302 enforces the pinned cap in the quote, so an
    ///      oversized batch to Solana reverts at prove time instead of being
    ///      verified and then failing delivery as an oversized Solana transaction.
    function test_fork_solanaCapsBatchAtSixProofs() public {
        if (!_forkOrSkip()) return;
        (LayerZeroProver prover, ) = _deploy();
        bytes memory data = abi.encode(
            LayerZeroProver.UnpackedData({
                sourceChainProver: bytes32(uint256(0x501a)),
                gasLimit: 0
            })
        );

        assertEq(_proofs(6).length, SOLANA_MAX_MESSAGE_SIZE);
        assertGt(prover.fetchFee(SOLANA_EID, _proofs(6), data), 0);

        vm.expectRevert(
            abi.encodeWithSignature(
                "LZ_MessageLib_InvalidMessageSize(uint256,uint256)",
                _proofs(7).length,
                SOLANA_MAX_MESSAGE_SIZE
            )
        );
        prover.fetchFee(SOLANA_EID, _proofs(7), data);

        // EVM destinations keep the 10000-byte cap.
        assertGt(prover.fetchFee(30101, _proofs(8), data), 0);
    }
}
