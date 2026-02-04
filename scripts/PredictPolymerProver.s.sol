// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {ICreate3Deployer} from "../contracts/tools/ICreate3Deployer.sol";

/**
 * @title PredictPolymerProver
 * @notice Script to predict the PolymerProver address before deployment
 * @dev Uses CREATE3 which gives the same address on all chains with same salt + deployer
 */
contract PredictPolymerProver is Script {
    ICreate3Deployer constant create3Deployer =
        ICreate3Deployer(0xC6BAd1EbAF366288dA6FB5689119eDd695a66814);

    function run() external view {
        // Load environment variables
        bytes32 rootSalt = vm.envBytes32("SALT");
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));

        // Compute contract-specific salt (same pattern as Deploy.s.sol)
        bytes32 polymerProverSalt = keccak256(
            abi.encode(rootSalt, keccak256(abi.encodePacked("POLYMER_PROVER")))
        );

        // Predict the address
        address predictedAddress = create3Deployer.deployedAddress(
            bytes(""), // Bytecode not needed for prediction
            deployer,
            polymerProverSalt
        );

        // Display results
        console.log("=== PolymerProver Address Prediction ===");
        console.log("");
        console.log("Deployer address:", deployer);
        console.log("Root salt:", vm.toString(rootSalt));
        console.log("Polymer salt:", vm.toString(polymerProverSalt));
        console.log("");
        console.log("Predicted address (same on ALL chains):");
        console.log("  ->", predictedAddress);
        console.log("");
        console.log("This address will be the same on:");
        console.log("  - Ethereum Mainnet (1)");
        console.log("  - Base (8453)");
        console.log("  - Any other chain");
        console.log("");
        console.log("Use this address in your whitelist!");
        console.log(
            "bytes32 selfAddress = bytes32(uint256(uint160(%s)));",
            predictedAddress
        );
    }
}
