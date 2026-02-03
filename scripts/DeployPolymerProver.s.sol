// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {PolymerProver} from "../contracts/prover/PolymerProver.sol";
import {ICreate3Deployer} from "../contracts/tools/ICreate3Deployer.sol";
import {AddressConverter} from "../contracts/libs/AddressConverter.sol";

/**
 * @title DeployPolymerProver
 * @notice Script to deploy PolymerProver using CREATE3 for deterministic cross-chain addresses
 * @dev The deployed prover will whitelist its own address, allowing it to receive messages
 *      from the same prover address on other chains
 */
contract DeployPolymerProver is Script {
    using AddressConverter for address;

    function run() external {
        // Load environment variables
        address portal = vm.envAddress("PORTAL_CONTRACT");
        address polymerCrossL2ProverV2 = vm.envAddress(
            "POLYMER_CROSS_L2_PROVER_V2"
        );
        bytes32 rootSalt = vm.envBytes32("SALT");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Configuration
        address create3Deployer = 0xC6BAd1EbAF366288dA6FB5689119eDd695a66814;

        // Compute contract-specific salt (same pattern as Deploy.s.sol)
        bytes32 polymerProverSalt = keccak256(
            abi.encode(rootSalt, keccak256(abi.encodePacked("POLYMER_PROVER")))
        );

        // Configuration
        uint256 maxLogDataSize = 32 * 1024; // 32KB

        console.log("=== PolymerProver Deployment Configuration ===");
        console.log("Chain ID:", block.chainid);
        console.log("Portal:", portal);
        console.log("Polymer CrossL2Prover V2:", polymerCrossL2ProverV2);
        console.log("Max Log Data Size:", maxLogDataSize, "bytes (32KB)");
        console.log("CREATE3 Deployer:", create3Deployer);
        console.log("Root Salt:", vm.toString(rootSalt));
        console.log("Polymer Salt:", vm.toString(polymerProverSalt));
        console.log("");

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        address deployer = vm.addr(deployerPrivateKey);

        // Step 1: Predict the deployed address
        bytes memory creationCode = type(PolymerProver).creationCode;
        address predictedAddress = ICreate3Deployer(create3Deployer)
            .deployedAddress(creationCode, deployer, polymerProverSalt);

        console.log("Predicted PolymerProver address:", predictedAddress);

        // Step 2: Load cross-VM provers from environment (if any)
        bytes32[] memory crossVmProvers;
        try vm.envBytes32("POLYMER_CROSS_VM_PROVERS", ",") returns (
            bytes32[] memory provers
        ) {
            crossVmProvers = provers;
        } catch {
            crossVmProvers = new bytes32[](0);
        }

        // Step 3: Create provers whitelist with predicted address + cross-VM provers
        bytes32[] memory provers = new bytes32[](1 + crossVmProvers.length);
        provers[0] = predictedAddress.toBytes32(); // Self-reference for cross-chain

        console.log("Provers whitelist:");
        console.log("  [0] (self):", vm.toString(provers[0]));

        for (uint256 i = 0; i < crossVmProvers.length; i++) {
            provers[i + 1] = crossVmProvers[i];
            console.log(
                "  [%s] (cross-VM):",
                i + 1,
                vm.toString(provers[i + 1])
            );
        }
        console.log("");

        // Step 4: Encode constructor arguments
        bytes memory constructorArgs = abi.encode(
            portal,
            polymerCrossL2ProverV2,
            maxLogDataSize,
            provers
        );

        // Step 5: Combine creation code with constructor arguments
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);

        console.log("Deploying PolymerProver via CREATE3...");

        // Step 6: Deploy using CREATE3
        address deployedAddress = ICreate3Deployer(create3Deployer).deploy(
            bytecode,
            polymerProverSalt
        );

        vm.stopBroadcast();

        // Verify deployment
        require(
            deployedAddress == predictedAddress,
            "Deployed address mismatch"
        );

        console.log("");
        console.log("=== Deployment Successful ===");
        console.log("PolymerProver deployed at:", deployedAddress);
        console.log(
            "Proof Type:",
            PolymerProver(deployedAddress).getProofType()
        );
        console.log(
            "Max Log Data Size:",
            PolymerProver(deployedAddress).MAX_LOG_DATA_SIZE(),
            "bytes"
        );
        console.log(
            "Whitelist Size:",
            PolymerProver(deployedAddress).getWhitelistSize()
        );

        // Verify the prover whitelisted itself
        require(
            PolymerProver(deployedAddress).isWhitelisted(
                deployedAddress.toBytes32()
            ),
            "Self-whitelisting verification failed"
        );
        console.log("Self-whitelisting: VERIFIED");
    }
}
