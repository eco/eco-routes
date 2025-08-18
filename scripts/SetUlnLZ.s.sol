// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {UlnConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {ILayerZeroEndpointV2} from "../contracts/interfaces/layerzero/ILayerZeroEndpointV2.sol";

contract SetSendConfig is Script {
    uint32 internal constant ULN_CONFIG_TYPE = 2;

    // DVN configuration
    uint8 internal constant REQUIRED_DVN_COUNT = 1;
    uint8 internal constant OPTIONAL_DVN_COUNT = 0;
    uint8 internal constant OPTIONAL_DVN_THRESHOLD = 0;

    // Chain configuration
    uint32 internal constant SRC_EID = 30111;  // Source chain endpoint ID
    uint32 internal constant DST_EID = 30420;  // Destination chain endpoint ID
    uint64 internal constant SEND_CONFIRMATIONS = 15;

    // Addresses - update with your actual contract addresses
    address internal constant OAPP_ADDRESS = 0xAA7AA40687bC87153fE46cb762815D0987816C13; 
    address internal constant DVN_ADDRESS = 0x427bd19a0463fc4eDc2e247d35eB61323d7E5541; //deutsche telekom
    address internal constant ENDPOINT_ADDRESS = 0x1a44076050125825900e736c501f859c50fE728c; // Optimism EndpointV2
    address internal constant LIB_ADDRESS = 0x1322871e4ab09Bc7f5717189434f97bBD9546e95; //deutsche telekom

    uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");


    address[] internal requiredDVNs;
    address[] internal optionalDVNs;

    function setUp() public {
        requiredDVNs = [DVN_ADDRESS];
        // optionalDVNs = []; // Add optional DVN addresses here if needed
    }

    /// @notice Configures send DVN settings for cross-chain communication
    function run() public {
        _setSendConfig(true); // CLI usage
    }

    function _setSendConfig(bool broadcast) public {
        if (broadcast) vm.startBroadcast(pk);

        console.log("=== Configuring Send DVN ===");
        console.log("OFT Address:", vm.toString(OAPP_ADDRESS));
        console.log("Destination EID:", vm.toString(DST_EID));
        console.log("DVN Address:", vm.toString(DVN_ADDRESS));
        console.log("Send Confirmations:", vm.toString(SEND_CONFIRMATIONS));
        
        UlnConfig memory ulnConfig = UlnConfig({
            confirmations: SEND_CONFIRMATIONS,
            requiredDVNCount: REQUIRED_DVN_COUNT,
            optionalDVNCount: OPTIONAL_DVN_COUNT,
            optionalDVNThreshold: OPTIONAL_DVN_THRESHOLD,
            requiredDVNs: requiredDVNs,
            optionalDVNs: optionalDVNs
        });

        bytes memory encodedULNConfig = abi.encode(ulnConfig);
        console.log("encodedULNConfig: ", vm.toString(encodedULNConfig));

        SetConfigParam[] memory sendConfigParams = new SetConfigParam[](1);
        sendConfigParams[0] = SetConfigParam({eid: DST_EID, configType: ULN_CONFIG_TYPE, config: abi.encode(ulnConfig)});
        
        // Cast to ILayerZeroEndpointV2 interface
        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(ENDPOINT_ADDRESS);

        endpoint.setConfig(OAPP_ADDRESS, LIB_ADDRESS, sendConfigParams);
        
        console.log("Send DVN configuration completed successfully!");

        if (broadcast) vm.stopBroadcast();
    }
}

contract SetReceiveConfig is Script {
    uint32 internal constant ULN_CONFIG_TYPE = 2;

    // DVN configuration
    uint8 internal constant REQUIRED_DVN_COUNT = 1;
    uint8 internal constant OPTIONAL_DVN_COUNT = 0;
    uint8 internal constant OPTIONAL_DVN_THRESHOLD = 0;

    // Chain configuration
    uint32 internal constant SRC_EID = 40161;  // Source chain endpoint ID
    uint32 internal constant DST_EID = 40168;  // Destination chain endpoint ID
    uint64 internal constant RECEIVE_CONFIRMATIONS = 10;

    // Addresses - update with your actual contract addresses
    address internal constant OAPP_ADDRESS = 0xAA7AA40687bC87153fE46cb762815D0987816C13;
    address internal constant DVN_ADDRESS = 0x427bd19a0463fc4eDc2e247d35eB61323d7E5541;
    address internal constant RECV_ULN = 0xdAf00F5eE2158dD58E0d3857851c432E34A3A851;
    address internal constant ENDPOINT_ADDRESS = 0x1a44076050125825900e736c501f859c50fE728c; // Optimism EndpointV2

    address[] internal requiredDVNs;
    address[] internal optionalDVNs;

    function setUp() public {
        requiredDVNs = [DVN_ADDRESS];
        // optionalDVNs = []; // Add optional DVN addresses here if needed
    }

    /// @notice Configures receive DVN settings for cross-chain communication
    function run() public {
        _setReceiveConfig(true); // CLI usage
    }

    function _setReceiveConfig(bool broadcast) public {
        if (broadcast) vm.startBroadcast();

        console.log("=== Configuring Receive DVN ===");
        console.log("O Address:", vm.toString(OAPP_ADDRESS));
        console.log("Destination EID:", vm.toString(DST_EID));
        console.log("Receive ULN:", vm.toString(RECV_ULN));
        console.log("DVN Address:", vm.toString(DVN_ADDRESS));
        console.log("Receive Confirmations:", vm.toString(RECEIVE_CONFIRMATIONS));
        
        UlnConfig memory ulnConfig = UlnConfig({
            confirmations: RECEIVE_CONFIRMATIONS,
            requiredDVNCount: REQUIRED_DVN_COUNT,
            optionalDVNCount: OPTIONAL_DVN_COUNT,
            optionalDVNThreshold: OPTIONAL_DVN_THRESHOLD,
            requiredDVNs: requiredDVNs,
            optionalDVNs: optionalDVNs
        });

        SetConfigParam[] memory receiveConfigParams = new SetConfigParam[](1);
        receiveConfigParams[0] = SetConfigParam({eid: DST_EID, configType: ULN_CONFIG_TYPE, config: abi.encode(ulnConfig)});

        // For LayerZero V2, we need to use the correct method signature
        // The setConfig method takes (eid, configType, config) parameters
        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(ENDPOINT_ADDRESS);
        endpoint.setConfig(DST_EID, ULN_CONFIG_TYPE, abi.encode(ulnConfig));
        
        console.log("Receive DVN configuration completed successfully!");

        if (broadcast) vm.stopBroadcast();
    }
}