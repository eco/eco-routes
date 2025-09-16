// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AddressPrediction} from "./AddressPrediction.sol";

/**
 * @title PredictAddresses
 * @notice Script for predicting contract addresses across multiple chains
 * @dev Uses AddressPrediction library to predict Polymer Prover addresses for chains with crossL2proverV2
 */
contract PredictAddresses is Script {
    using AddressPrediction for *;

    /**
     * @notice Predict Polymer Prover address for a specific chain
     * @param chainId The chain ID
     * @param salt The root salt
     * @param deployer The deployer address
     * @return The predicted address
     */
    function predictPolymerProverForChain(
        uint256 chainId,
        bytes32 salt,
        address deployer
    ) public pure returns (address) {
        // Generate contract-specific salt for Polymer Prover
        bytes32 polymerSalt = AddressPrediction.getContractSalt(salt, "POLYMER_PROVER");

        // Predict the CREATE3 address for this chain
        return AddressPrediction.predictCreate3Address(chainId, polymerSalt, deployer);
    }

    /**
     * @notice Predict Polymer Prover addresses for all target chains and return unique ones
     * @dev Reads TARGET_CHAIN_IDS from environment and predicts for each chain
     * @return Array of unique predicted addresses
     */
    function predictPolymerProverForAllChains() external returns (address[] memory) {
        bytes32 salt = vm.envBytes32("SALT");
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        // Get target chain IDs from environment (chains with crossL2proverV2)
        uint256[] memory chainIds = getTargetChainIds();

        console.log("=== Predicting Polymer Prover Addresses ===");
        console.log("Salt:", vm.toString(salt));
        console.log("Deployer:", deployer);
        console.log("Target chains:", chainIds.length);
        console.log("");

        // Array to store predictions and track uniqueness
        address[] memory predictions = new address[](chainIds.length);
        uint256 uniqueCount = 0;

        // Predict address for each chain
        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            address predicted = predictPolymerProverForChain(chainId, salt, deployer);

            console.log("Chain", chainId, "Predicted:", predicted);

            // Check if this address is unique
            bool isUnique = true;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (predictions[j] == predicted) {
                    isUnique = false;
                    console.log("  -> Duplicate of chain", getChainIdForAddress(chainIds, predictions, j));
                    break;
                }
            }

            // If unique, add to our list
            if (isUnique) {
                predictions[uniqueCount] = predicted;
                uniqueCount++;
                console.log("  -> UNIQUE");
            }
        }

        console.log("");
        console.log("=== Summary ===");
        console.log("Total chains processed:", chainIds.length);
        console.log("Unique addresses found:", uniqueCount);
        console.log("");

        // Create array with only unique addresses to return
        address[] memory uniqueAddresses = new address[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            uniqueAddresses[i] = predictions[i];
        }

        // Output unique addresses in format that TypeScript can parse
        console.log("=== Unique Addresses for Cross-VM Provers ===");
        for (uint256 i = 0; i < uniqueCount; i++) {
            console.log("UNIQUE_ADDRESS:", uniqueAddresses[i]);
        }

        console.log("");
        console.log("=== Chain Mapping ===");
        for (uint256 i = 0; i < chainIds.length; i++) {
            address predicted = predictPolymerProverForChain(chainIds[i], salt, deployer);
            console.log("CHAIN_MAPPING:", chainIds[i], predicted);
        }

        return uniqueAddresses;
    }

    /**
     * @notice Get target chain IDs from environment variable
     * @dev Reads TARGET_CHAIN_IDS (comma-separated) and parses them
     * @return Array of chain IDs
     */
    function getTargetChainIds() internal view returns (uint256[] memory) {
        // Fetch chain IDs from environment variable
        // These should be the chains with crossL2proverV2 field from CHAIN_DATA_URL
        string memory chainIdsStr = vm.envString("TARGET_CHAIN_IDS");

        require(bytes(chainIdsStr).length > 0, "TARGET_CHAIN_IDS not set");

        // Parse comma-separated chain IDs
        return parseChainIds(chainIdsStr);
    }

    /**
     * @notice Parse comma-separated chain IDs string into uint256 array
     * @param chainIdsStr Comma-separated string of chain IDs
     * @return Array of parsed chain IDs
     */
    function parseChainIds(string memory chainIdsStr) internal pure returns (uint256[] memory) {
        bytes memory chainIdsBytes = bytes(chainIdsStr);

        // Count commas to determine array size
        uint256 commaCount = 0;
        for (uint256 i = 0; i < chainIdsBytes.length; i++) {
            if (chainIdsBytes[i] == ",") {
                commaCount++;
            }
        }

        // Array size is comma count + 1
        uint256[] memory chainIds = new uint256[](commaCount + 1);
        uint256 arrayIndex = 0;
        uint256 currentNumber = 0;

        // Parse each character
        for (uint256 i = 0; i < chainIdsBytes.length; i++) {
            bytes1 char = chainIdsBytes[i];

            if (char == ",") {
                // End of current number
                chainIds[arrayIndex] = currentNumber;
                arrayIndex++;
                currentNumber = 0;
            } else if (char >= "0" && char <= "9") {
                // Add digit to current number
                currentNumber = currentNumber * 10 + uint256(uint8(char)) - 48;
            }
            // Ignore spaces and other characters
        }

        // Add the last number
        if (arrayIndex < chainIds.length) {
            chainIds[arrayIndex] = currentNumber;
        }

        return chainIds;
    }

    /**
     * @notice Helper to find which chain ID corresponds to an address in the predictions array
     * @param chainIds Array of chain IDs
     * @param predictions Array of predicted addresses
     * @param index Index in predictions array
     * @return The chain ID that generated this address
     */
    function getChainIdForAddress(
        uint256[] memory chainIds,
        address[] memory predictions,
        uint256 index
    ) internal pure returns (uint256) {
        if (index < chainIds.length) {
            return chainIds[index];
        }
        return 0;
    }

    /**
     * @notice Convenience function to predict a single address for testing
     * @param chainId The chain ID
     * @param contractName The contract name (e.g., "POLYMER_PROVER")
     * @return The predicted address
     */
    function predictSingleAddress(uint256 chainId, string memory contractName) external view returns (address) {
        bytes32 salt = vm.envBytes32("SALT");
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        bytes32 contractSalt = AddressPrediction.getContractSalt(salt, contractName);
        address predicted = AddressPrediction.predictCreate3Address(chainId, contractSalt, deployer);

        console.log("=== Single Address Prediction ===");
        console.log("Chain ID:", chainId);
        console.log("Contract:", contractName);
        console.log("Salt:", vm.toString(salt));
        console.log("Contract Salt:", vm.toString(contractSalt));
        console.log("Deployer:", deployer);
        console.log("Uses CreateX:", AddressPrediction.useCreateXForChainID(chainId));
        console.log("Predicted Address:", predicted);

        return predicted;
    }

    /**
     * @notice Debug function to show deployment system for each chain
     */
    function debugDeploymentSystems() external view {
        uint256[] memory chainIds = getTargetChainIds();

        console.log("=== Deployment Systems ===");
        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            bool usesCreateX = AddressPrediction.useCreateXForChainID(chainId);
            bool isTron = AddressPrediction.isTronChain(chainId);

            console.log("Chain", chainId, ":");
            console.log("  Uses CreateX:", usesCreateX);
            console.log("  Is Tron:", isTron);

            if (usesCreateX) {
                console.log("  Deployment System: CreateX");
            } else if (isTron) {
                console.log("  Deployment System: CREATE2 (Tron prefix)");
            } else {
                console.log("  Deployment System: Create3Deployer");
            }
        }
    }
}