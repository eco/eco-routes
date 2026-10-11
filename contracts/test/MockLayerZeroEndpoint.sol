// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// solhint-disable one-contract-per-file
// solhint-disable gas-custom-errors

import {ILayerZeroEndpointV2} from "../interfaces/layerzero/ILayerZeroEndpointV2.sol";
import {ILayerZeroReceiver} from "../interfaces/layerzero/ILayerZeroReceiver.sol";

/**
 * @dev The EndpointV2 OApp-configuration surface LayerZeroProver uses, with the
 *      real endpoint's access rule: only the OApp itself or its delegate may
 *      configure it. Stores configs verbatim so tests can read back exactly
 *      what the prover pinned.
 */
abstract contract LayerZeroEndpointConfigMock {
    mapping(address => address) public delegates;
    mapping(address => mapping(uint32 => address)) public sendLibrary;
    mapping(address => mapping(uint32 => address)) public receiveLibrary;
    mapping(address => mapping(uint32 => uint256))
        public receiveLibraryGracePeriod;
    mapping(address => mapping(address => mapping(uint32 => mapping(uint32 => bytes))))
        internal _configs;

    modifier onlyAuthorized(address oapp) {
        if (msg.sender != oapp && msg.sender != delegates[oapp]) {
            revert("LZ_Unauthorized");
        }
        _;
    }

    function setDelegate(address delegate) external {
        delegates[msg.sender] = delegate;
    }

    function setSendLibrary(
        address oapp,
        uint32 eid,
        address lib
    ) external onlyAuthorized(oapp) {
        sendLibrary[oapp][eid] = lib;
    }

    function setReceiveLibrary(
        address oapp,
        uint32 eid,
        address lib,
        uint256 gracePeriod
    ) external onlyAuthorized(oapp) {
        receiveLibrary[oapp][eid] = lib;
        receiveLibraryGracePeriod[oapp][eid] = gracePeriod;
    }

    function setConfig(
        address oapp,
        address lib,
        ILayerZeroEndpointV2.SetConfigParam[] calldata params
    ) external onlyAuthorized(oapp) {
        for (uint256 i = 0; i < params.length; i++) {
            _configs[oapp][lib][params[i].eid][params[i].configType] = params[i]
                .config;
        }
    }

    function getConfig(
        address oapp,
        address lib,
        uint32 eid,
        uint32 configType
    ) external view returns (bytes memory) {
        return _configs[oapp][lib][eid][configType];
    }
}

contract MockLayerZeroEndpoint is LayerZeroEndpointConfigMock {
    uint256 public constant FEE = 0.001 ether;
    bool public dispatched;

    function send(
        ILayerZeroEndpointV2.MessagingParams calldata params,
        address refundAddress
    ) external payable returns (ILayerZeroEndpointV2.MessagingReceipt memory) {
        if (msg.value < FEE) revert("Insufficient fee");
        dispatched = true;

        // Refund excess
        if (msg.value > FEE) {
            (bool success, ) = refundAddress.call{value: msg.value - FEE}("");
            if (!success) revert("Refund failed");
        }

        return
            ILayerZeroEndpointV2.MessagingReceipt({
                guid: keccak256(abi.encode(params, block.timestamp)),
                nonce: 1,
                fee: ILayerZeroEndpointV2.MessagingFee({
                    nativeFee: FEE,
                    lzTokenFee: 0
                })
            });
    }

    function quote(
        ILayerZeroEndpointV2.MessagingParams calldata /* params */,
        address /* sender */
    ) external pure returns (ILayerZeroEndpointV2.MessagingFee memory) {
        return
            ILayerZeroEndpointV2.MessagingFee({nativeFee: FEE, lzTokenFee: 0});
    }
}

contract TestLayerZeroEndpoint is MockLayerZeroEndpoint {
    address public receiver;

    function setReceiver(address _receiver) external {
        receiver = _receiver;
    }

    function simulateReceive(
        uint32 srcEid,
        bytes32 sender,
        bytes calldata message
    ) external {
        ILayerZeroReceiver(receiver).lzReceive(
            ILayerZeroReceiver.Origin({
                srcEid: srcEid,
                sender: sender,
                nonce: 1
            }),
            bytes32(0),
            message,
            address(0),
            ""
        );
    }
}
