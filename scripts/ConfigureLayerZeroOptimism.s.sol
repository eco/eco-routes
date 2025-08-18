// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {UlnConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import {ILayerZeroEndpointV2} from "../contracts/interfaces/layerzero/ILayerZeroEndpointV2.sol";

contract ConfigureLayerZeroOptimism is Script {
    uint32 internal constant ULN_CONFIG_TYPE = 2;
    uint32 internal constant CONFIG_TYPE_EXECUTOR = 1;

    // DVN configuration
    uint8 internal constant REQUIRED_DVN_COUNT = 1;
    uint8 internal constant OPTIONAL_DVN_COUNT = 0;
    uint8 internal constant OPTIONAL_DVN_THRESHOLD = 0;

    // Executor configuration
    uint128 internal constant EXECUTOR_GAS_LIMIT = 800000;
    uint128 internal constant EXECUTOR_VALUE = 0;

    // Chain configuration
    uint32 internal constant OPTIMISM_EID = 30111;  // Optimism chain endpoint ID
    uint32 internal constant TRON_EID = 30420;     // Tron chain endpoint ID
    uint64 internal constant SEND_CONFIRMATIONS = 15;
    uint64 internal constant RECEIVE_CONFIRMATIONS = 10;

    // Contract addresses from environment
    address internal LAYERZERO_PROVER_ADDRESS;
    address internal DVN_ADDRESS;
    address internal ENDPOINT_ADDRESS;
    address internal SEND_LIB_ADDRESS;
    address internal RECEIVE_LIB_ADDRESS;
    address internal EXECUTOR_ADDRESS;

    uint256 pk;

    address[] internal requiredDVNs;
    address[] internal optionalDVNs;

    function setUp() public {
        // Load addresses from environment
        LAYERZERO_PROVER_ADDRESS = vm.envAddress("OP_LAYERZERO_PROVER");
        DVN_ADDRESS = vm.envOr("OP_DVN_ADDRESS", address(0x6A02D83e8d433304bba74EF1c427913958187142)); // layerzero labs
        ENDPOINT_ADDRESS = vm.envAddress("OP_LAYERZERO_ENDPOINT");
        SEND_LIB_ADDRESS = vm.envOr("OP_SEND_LIB_ADDRESS", address(0x1322871e4ab09Bc7f5717189434f97bBD9546e95)); //default send lib
        RECEIVE_LIB_ADDRESS = vm.envOr("OP_RECEIVE_LIB_ADDRESS", address(0x3c4962Ff6258dcfCafD23a814237B7d6Eb712063)); // default receive lib
        EXECUTOR_ADDRESS = vm.envOr("OP_EXECUTOR_ADDRESS", address(0x2D2ea0697bdbede3F01553D2Ae4B8d0c486B666e)); // LayerZero Executor

        pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        requiredDVNs = [DVN_ADDRESS];
        // optionalDVNs = []; // Add optional DVN addresses here if needed
    }

    /// @notice Set send library for LayerZero endpoint
    function setSendLibrary() public {
        vm.startBroadcast(pk);

        console.log("=== Setting Send Library ===");
        console.log("LayerZero Prover Address:", vm.toString(LAYERZERO_PROVER_ADDRESS));
        console.log("Destination EID:", vm.toString(TRON_EID));
        console.log("Send Library Address:", vm.toString(SEND_LIB_ADDRESS));

        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(ENDPOINT_ADDRESS);
        endpoint.setSendLibrary(LAYERZERO_PROVER_ADDRESS, TRON_EID, SEND_LIB_ADDRESS);

        console.log("Send library configuration completed successfully!");
        vm.stopBroadcast();
    }

    /// @notice Set receive library for LayerZero endpoint
    function setReceiveLibrary() public {
        vm.startBroadcast(pk);

        console.log("=== Setting Receive Library ===");
        console.log("LayerZero Prover Address:", vm.toString(LAYERZERO_PROVER_ADDRESS));
        console.log("Source EID:", vm.toString(TRON_EID));
        console.log("Receive Library Address:", vm.toString(RECEIVE_LIB_ADDRESS));

        uint256 gracePeriod = 86400; // 24 hours

        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(ENDPOINT_ADDRESS);
        endpoint.setReceiveLibrary(LAYERZERO_PROVER_ADDRESS, TRON_EID, RECEIVE_LIB_ADDRESS, gracePeriod);

        console.log("Receive library configuration completed successfully!");
        console.log("Grace Period:", vm.toString(gracePeriod), "seconds");
        vm.stopBroadcast();
    }

    /// @notice Set executor configuration
    function setExecutor() public {
        vm.startBroadcast(pk);

        console.log("=== Setting Executor Configuration ===");
        console.log("LayerZero Prover Address:", vm.toString(LAYERZERO_PROVER_ADDRESS));
        console.log("Send Library Address:", vm.toString(SEND_LIB_ADDRESS));
        console.log("Executor Address:", vm.toString(EXECUTOR_ADDRESS));
        console.log("Gas Limit:", vm.toString(EXECUTOR_GAS_LIMIT));
        console.log("Value:", vm.toString(EXECUTOR_VALUE));

        // Create executor configuration: abi.encode(uint128 gasLimit, uint128 value)
        bytes memory executorConfig = abi.encode(EXECUTOR_GAS_LIMIT, EXECUTOR_VALUE);
        
        // Full executor config: abi.encode(address executor, bytes executorConfig)
        bytes memory fullExecutorConfig = abi.encode(EXECUTOR_ADDRESS, executorConfig);

        SetConfigParam[] memory setConfigParams = new SetConfigParam[](1);
        setConfigParams[0] = SetConfigParam({
            eid: TRON_EID,
            configType: CONFIG_TYPE_EXECUTOR,
            config: fullExecutorConfig
        });

        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(ENDPOINT_ADDRESS);
        endpoint.setConfig(LAYERZERO_PROVER_ADDRESS, SEND_LIB_ADDRESS, setConfigParams);

        console.log("Executor configuration completed successfully!");
        vm.stopBroadcast();
    }

    /// @notice Configure send DVN settings for cross-chain communication
    function configureSend() public {
        vm.startBroadcast(pk);

        console.log("=== Configuring Send DVN ===");
        console.log("LayerZero Prover Address:", vm.toString(LAYERZERO_PROVER_ADDRESS));
        console.log("Destination EID:", vm.toString(TRON_EID));
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
        console.log("Encoded ULN Config:", vm.toString(encodedULNConfig));

        SetConfigParam[] memory sendConfigParams = new SetConfigParam[](1);
        sendConfigParams[0] = SetConfigParam({
            eid: TRON_EID,
            configType: ULN_CONFIG_TYPE,
            config: encodedULNConfig
        });

        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(ENDPOINT_ADDRESS);
        endpoint.setConfig(LAYERZERO_PROVER_ADDRESS, SEND_LIB_ADDRESS, sendConfigParams);

        console.log("Send DVN configuration completed successfully!");
        vm.stopBroadcast();
    }

    /// @notice Configure receive DVN settings for cross-chain communication
    function configureReceive() public {
        vm.startBroadcast(pk);

        console.log("=== Configuring Receive DVN ===");
        console.log("LayerZero Prover Address:", vm.toString(LAYERZERO_PROVER_ADDRESS));
        console.log("Source EID:", vm.toString(TRON_EID));
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

        bytes memory encodedULNConfig = abi.encode(ulnConfig);
        console.log("Encoded ULN Config:", vm.toString(encodedULNConfig));

        SetConfigParam[] memory receiveConfigParams = new SetConfigParam[](1);
        receiveConfigParams[0] = SetConfigParam({
            eid: TRON_EID,
            configType: ULN_CONFIG_TYPE,
            config: encodedULNConfig
        });

        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(ENDPOINT_ADDRESS);
        endpoint.setConfig(LAYERZERO_PROVER_ADDRESS, RECEIVE_LIB_ADDRESS, receiveConfigParams);

        console.log("Receive DVN configuration completed successfully!");
        vm.stopBroadcast();
    }

    /// @notice Complete send setup: set send library, executor, and send DVN config
    function setupSend() public {
        // setSendLibrary();
        // setExecutor();
        configureSend();
        console.log("Complete send setup finished!");
    }

    /// @notice Complete receive setup: set receive library and receive DVN config
    function setupReceive() public {
        // setReceiveLibrary();
        configureReceive();
        console.log("Complete receive setup finished!");
    }

    /// @notice Get sender configuration from LayerZero endpoint
    function getConfigSender() public view {
        console.log("=== Getting Sender Configuration ===");
        console.log("getConfig method inputs:");
        console.log("  Endpoint Address:", vm.toString(ENDPOINT_ADDRESS));
        console.log("  LayerZero Prover Address:", vm.toString(LAYERZERO_PROVER_ADDRESS));
        console.log("  Send Library Address:", vm.toString(SEND_LIB_ADDRESS));
        console.log("  Chain EID:", vm.toString(TRON_EID));
        console.log("  Config Type:", vm.toString(ULN_CONFIG_TYPE));

        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(ENDPOINT_ADDRESS);
        bytes memory config = endpoint.getConfig(
            LAYERZERO_PROVER_ADDRESS,
            SEND_LIB_ADDRESS,
            TRON_EID,
            ULN_CONFIG_TYPE
        );

        console.log("Raw sender config result:");
        console.logBytes(config);

        if (config.length > 0) {
            // Try to decode UlnConfig
            try this.decodeUlnConfig(config) returns (UlnConfig memory ulnConfig) {
                console.log("Parsed sender configuration:");
                console.log("  Confirmations:", vm.toString(ulnConfig.confirmations));
                console.log("  Required DVN Count:", vm.toString(ulnConfig.requiredDVNCount));
                console.log("  Optional DVN Count:", vm.toString(ulnConfig.optionalDVNCount));
                console.log("  Optional DVN Threshold:", vm.toString(ulnConfig.optionalDVNThreshold));
                
                if (ulnConfig.requiredDVNs.length > 0) {
                    console.log("  Primary DVN:", vm.toString(ulnConfig.requiredDVNs[0]));
                }
                
                for (uint256 i = 0; i < ulnConfig.requiredDVNs.length; i++) {
                    console.log("  Required DVN", vm.toString(i), ":", vm.toString(ulnConfig.requiredDVNs[i]));
                }
            } catch {
                console.log("Failed to decode ULN config - raw bytes shown above");
            }
        } else {
            console.log("No configuration found");
        }
    }

    /// @notice Get receiver configuration from LayerZero endpoint
    function getConfigReceiver() public view {
        console.log("=== Getting Receiver Configuration ===");
        console.log("getConfig method inputs:");
        console.log("  Endpoint Address:", vm.toString(ENDPOINT_ADDRESS));
        console.log("  LayerZero Prover Address:", vm.toString(LAYERZERO_PROVER_ADDRESS));
        console.log("  Receive Library Address:", vm.toString(RECEIVE_LIB_ADDRESS));
        console.log("  Chain EID:", vm.toString(TRON_EID));
        console.log("  Config Type:", vm.toString(ULN_CONFIG_TYPE));

        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(ENDPOINT_ADDRESS);
        bytes memory config = endpoint.getConfig(
            LAYERZERO_PROVER_ADDRESS,
            RECEIVE_LIB_ADDRESS,
            TRON_EID,
            ULN_CONFIG_TYPE
        );

        console.log("Raw receiver config result:");
        console.logBytes(config);

        if (config.length > 0) {
            // Try to decode UlnConfig
            try this.decodeUlnConfig(config) returns (UlnConfig memory ulnConfig) {
                console.log("Parsed receiver configuration:");
                console.log("  Confirmations:", vm.toString(ulnConfig.confirmations));
                console.log("  Required DVN Count:", vm.toString(ulnConfig.requiredDVNCount));
                console.log("  Optional DVN Count:", vm.toString(ulnConfig.optionalDVNCount));
                console.log("  Optional DVN Threshold:", vm.toString(ulnConfig.optionalDVNThreshold));
                
                if (ulnConfig.requiredDVNs.length > 0) {
                    console.log("  Primary DVN:", vm.toString(ulnConfig.requiredDVNs[0]));
                }
                
                for (uint256 i = 0; i < ulnConfig.requiredDVNs.length; i++) {
                    console.log("  Required DVN", vm.toString(i), ":", vm.toString(ulnConfig.requiredDVNs[i]));
                }
            } catch {
                console.log("Failed to decode ULN config - raw bytes shown above");
            }
        } else {
            console.log("No configuration found");
        }
    }

    /// @notice Get executor configuration from LayerZero endpoint
    function getExecutor() public view {
        console.log("=== Getting Executor Configuration ===");
        console.log("getConfig method inputs:");
        console.log("  Endpoint Address:", vm.toString(ENDPOINT_ADDRESS));
        console.log("  LayerZero Prover Address:", vm.toString(LAYERZERO_PROVER_ADDRESS));
        console.log("  Send Library Address:", vm.toString(SEND_LIB_ADDRESS));
        console.log("  Chain EID:", vm.toString(TRON_EID));
        console.log("  Config Type: 1 (Executor)");

        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(ENDPOINT_ADDRESS);
        bytes memory config = endpoint.getConfig(
            LAYERZERO_PROVER_ADDRESS,
            SEND_LIB_ADDRESS,
            TRON_EID,
            1 // CONFIG_TYPE_EXECUTOR
        );

        console.log("Raw executor config result:");
        console.logBytes(config);

        if (config.length > 0) {
            console.log("Executor configuration found (length:", vm.toString(config.length), "bytes)");
            // Executor config is typically: abi.encode(address executor, bytes executorConfig)
            // where executorConfig is: abi.encode(uint128 gasLimit, uint128 value)
            
            if (config.length >= 64) {
                // Try to decode executor address (first 32 bytes after offset)
                bytes32 executorBytes;
                assembly {
                    executorBytes := mload(add(config, 0x40)) // Skip length + offset
                }
                address executorAddress = address(uint160(uint256(executorBytes)));
                console.log("  Executor Address:", vm.toString(executorAddress));
            }
        } else {
            console.log("No executor configuration found");
        }
    }

    /// @notice Get current configuration status
    function getCurrentConfig() public view {
        console.log("=== Getting Current Configuration Status ===");
        console.log("LayerZero Prover:", vm.toString(LAYERZERO_PROVER_ADDRESS));
        console.log("Endpoint:", vm.toString(ENDPOINT_ADDRESS));
        console.log("DVN:", vm.toString(DVN_ADDRESS));
        console.log("");
        
        getConfigSender();
        console.log("");
        getConfigReceiver();
        
        console.log("Configuration retrieval completed");
    }

    /// @notice Helper function to decode UlnConfig
    function decodeUlnConfig(bytes memory data) external pure returns (UlnConfig memory) {
        return abi.decode(data, (UlnConfig));
    }

    /// @notice Run full LayerZero configuration setup
    function run() public {
        console.log("=== LayerZero Optimism Configuration ===");
        console.log("Endpoint Address:", vm.toString(ENDPOINT_ADDRESS));
        console.log("LayerZero Prover Address:", vm.toString(LAYERZERO_PROVER_ADDRESS));
        console.log("Target Chain EID (Tron):", vm.toString(TRON_EID));
        console.log("");

        setupSend();
        setupReceive();

        console.log("=== LayerZero Optimism Configuration Complete ===");
    }
}