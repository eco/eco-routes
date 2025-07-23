// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ICreate3Deployer} from "../contracts/tools/ICreate3Deployer.sol";
import {LayerZeroProver} from "../contracts/prover/LayerZeroProver.sol";

contract LayerZeroProverDeployer is Script {
    ICreate3Deployer constant create3Deployer =
        ICreate3Deployer(0xC6BAd1EbAF366288dA6FB5689119eDd695a66814);

    function run() external {
        // Predict addresses for different networks
        predictOptimismAddress();
    }

    function predictOptimismAddress() public view {
        bytes memory layerZeroProverBytecode = type(LayerZeroProver).creationCode;
        address sender = address(this);
        bytes32 salt = vm.envBytes32("SALT");
        
        address predicted = create3Deployer.deployedAddress(layerZeroProverBytecode, sender, salt);
        console.log("=== OPTIMISM LAYERZERO PROVER ===");
        console.log("Predicted address:", predicted);
        console.log("Sender address:", sender);
        console.log("Salt:", vm.toString(salt));
        console.log("Bytecode length:", layerZeroProverBytecode.length);
        console.log("");
    }

    function predictAddressWithCustomSalt(bytes32 salt) external view returns (address) {
        bytes memory layerZeroProverBytecode = type(LayerZeroProver).creationCode;
        address sender = address(this);
        
        address predicted = create3Deployer.deployedAddress(layerZeroProverBytecode, sender, salt);
        console.log("Predicted address:", predicted);
        console.log("Sender address:", sender);
        console.log("Salt:", vm.toString(salt));
        console.log("Bytecode length:", layerZeroProverBytecode.length);
        
        return predicted;
    }

    function predictAddressWithCustomSender(address sender, bytes32 salt) external view returns (address) {
        bytes memory layerZeroProverBytecode = type(LayerZeroProver).creationCode;
        
        address predicted = create3Deployer.deployedAddress(layerZeroProverBytecode, sender, salt);
        console.log("Predicted address:", predicted);
        console.log("Sender address:", sender);
        console.log("Salt:", vm.toString(salt));
        console.log("Bytecode length:", layerZeroProverBytecode.length);
        
        return predicted;
    }

    function deployLayerZeroProver() external returns (address) {
        bytes memory layerZeroProverBytecode = type(LayerZeroProver).creationCode;
        bytes32 salt = vm.envBytes32("SALT");
        
        // Predict the address first
        address predicted = create3Deployer.deployedAddress(layerZeroProverBytecode, address(this), salt);
        console.log("=== DEPLOYING LAYERZERO PROVER ===");
        console.log("Predicted address:", predicted);
        console.log("Salt:", vm.toString(salt));
        console.log("Bytecode length:", layerZeroProverBytecode.length);
        
        // Check if already deployed
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(predicted)
        }
        if (codeSize > 0) {
            console.log("Contract already deployed at:", predicted);
            return predicted;
        }
        
        // Deploy using CREATE3
        address deployed = create3Deployer.deploy(layerZeroProverBytecode, salt);
        console.log("Deployed at:", deployed);
        
        require(deployed == predicted, "Address mismatch");
        console.log("Nice! Deployment successful!");
        
        return deployed;
    }

    function deployLayerZeroProverWithConstructor(
        address endpoint,
        address portal,
        bytes32[] memory provers,
        uint256 defaultGasLimit
    ) external returns (address) {
        bytes32 salt = vm.envBytes32("SALT");
        
        // Encode constructor parameters
        bytes memory constructorArgs = abi.encode(endpoint, portal, provers, defaultGasLimit);
        
        // Get creation code and encode with constructor args
        bytes memory layerZeroProverBytecode = abi.encodePacked(
            type(LayerZeroProver).creationCode,
            constructorArgs
        );
        
        // Predict the address first
        address predicted = create3Deployer.deployedAddress(layerZeroProverBytecode, address(this), salt);
        console.log("=== DEPLOYING LAYERZERO PROVER WITH CONSTRUCTOR ===");
        console.log("Predicted address:", predicted);
        console.log("Endpoint:", endpoint);
        console.log("Portal:", portal);
        console.log("Default gas limit:", defaultGasLimit);
        console.log("Salt:", vm.toString(salt));
        console.log("Bytecode length:", layerZeroProverBytecode.length);
        
        // Check if already deployed
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(predicted)
        }
        if (codeSize > 0) {
            console.log("Contract already deployed at:", predicted);
            return predicted;
        }
        
        // Deploy using CREATE3
        address deployed = create3Deployer.deploy(layerZeroProverBytecode, salt);
        console.log("Deployed at:", deployed);
        
        require(deployed == predicted, "Address mismatch");
        console.log("Deployment successful!");
        
        return deployed;
    }

    // Simplified deployment function that uses environment variables
    function deployLayerZeroProverWithEnv() external returns (address) {
        address endpoint = vm.envAddress("LAYERZERO_ENDPOINT");
        address portal = vm.envAddress("PORTAL_ADDRESS");
        uint256 defaultGasLimit = vm.envUint("DEFAULT_GAS_LIMIT");
        
        // Read provers from environment variable (comma-separated addresses)
        string memory proversStr = vm.envString("PROVERS");
        bytes32[] memory provers = parseProversString(proversStr);
        
        return this.deployLayerZeroProverWithConstructor(endpoint, portal, provers, defaultGasLimit);
    }

    // Test deployment with hardcoded values
    function deployLayerZeroProverWithHardcoded() external returns (address) {
        address endpoint = 0x1a44076050125825900e736c501f859c50fE728c;
        address portal = 0x23f2BCc69d3d2a84e22Eae1425b2d26DeeCD898B;
        uint256 defaultGasLimit = 200000;
        
        // Add a test prover address
        bytes32[] memory provers = new bytes32[](1);
        provers[0] = bytes32(uint256(uint160(0x1234567890123456789012345678901234567890)));
        
        return this.deployLayerZeroProverWithConstructor(endpoint, portal, provers, defaultGasLimit);
    }

    function parseProversString(string memory proversStr) internal pure returns (bytes32[] memory) {
        // If empty string, return empty array
        if (bytes(proversStr).length == 0) {
            return new bytes32[](0);
        }
        
        // Count commas to determine array size
        uint256 count = 1;
        for (uint256 i = 0; i < bytes(proversStr).length; i++) {
            if (bytes(proversStr)[i] == ",") {
                count++;
            }
        }
        
        bytes32[] memory provers = new bytes32[](count);
        uint256 currentIndex = 0;
        uint256 startIndex = 0;
        
        for (uint256 i = 0; i < bytes(proversStr).length; i++) {
            if (bytes(proversStr)[i] == "," || i == bytes(proversStr).length - 1) {
                uint256 endIndex = (i == bytes(proversStr).length - 1) ? i + 1 : i;
                string memory addrStr = substring(proversStr, startIndex, endIndex);
                provers[currentIndex] = bytes32(uint256(uint160(vm.parseAddress(addrStr))));
                currentIndex++;
                startIndex = i + 1;
            }
        }
        
        return provers;
    }

    function substring(string memory str, uint256 startIndex, uint256 endIndex) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }
        return string(result);
    }
} 