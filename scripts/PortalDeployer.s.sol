// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Forge
import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Tools
import {SingletonFactory} from "../contracts/tools/SingletonFactory.sol";
import {ICreate3Deployer} from "../contracts/tools/ICreate3Deployer.sol";

// Protocol
import {Portal} from "../contracts/Portal.sol";

contract PortalDeployer is Script {
    SingletonFactory constant create2Factory =
        SingletonFactory(0xce0042B868300000d44A59004Da54A005ffdcf9f);

    // Create3Deployer
    ICreate3Deployer constant create3Deployer =
        ICreate3Deployer(0xC6BAd1EbAF366288dA6FB5689119eDd695a66814);

    /**
     * @notice Checks if a contract is already deployed at the given address
     * @param _addr The address to check
     * @return True if a contract is deployed at the address, false otherwise
     */
    function isDeployed(address _addr) external view returns (bool) {
        return _addr.code.length > 0;
    }

    /**
     * @notice Gets the contract salt for a specific contract name
     * @param rootSalt The root salt used for deployment
     * @param contractName The name of the contract
     * @return The computed salt for the contract
     */
    function getContractSalt(
        bytes32 rootSalt,
        string memory contractName
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encode(rootSalt, keccak256(abi.encodePacked(contractName)))
            );
    }

    /**
     * @notice Gets the Portal salt using environment variable root salt
     * @return The computed salt for Portal
     */
    function getPortalSalt() external view returns (bytes32) {
        bytes32 rootSalt = vm.envBytes32("SALT");
        return this.getContractSalt(rootSalt, "PORTAL");
    }

    /**
     * @notice Predicts the address where a contract will be deployed using CREATE3
     * @param bytecode The bytecode of the contract to be deployed
     * @param sender The sender address
     * @param salt The salt used for the CREATE3 deployment
     * @return The predicted address where the contract will be deployed
     */
    function predictCreate3Address(
        bytes memory bytecode,
        address sender,
        bytes32 salt
    ) external view returns (address) {
        return create3Deployer.deployedAddress(bytecode, sender, salt);
    }

    /**
     * @notice Predicts the address where Portal will be deployed using CREATE3
     * @param sender The sender address
     * @param salt The salt used for the CREATE3 deployment
     * @return The predicted address where Portal will be deployed
     */
    function predictPortalAddress(address sender, bytes32 salt) external view returns (address) {
        bytes memory portalBytecode = vm.getDeployedCode("Portal.sol:Portal");
        // The CREATE3 deployer uses the address calling the deployer as the sender
        return create3Deployer.deployedAddress(portalBytecode, address(this), salt);
    }

    /**
     * @notice Predicts Portal address using environment variable salt
     * @return The predicted address where Portal will be deployed
     */
    function predictPortalAddressWithEnvSalt() external view returns (address) {
        bytes32 salt = this.getPortalSalt();
        return this.predictPortalAddress(address(this), salt);
    }

    /**
     * @notice Predicts the address where a contract will be deployed using CREATE2
     * @param bytecode The bytecode of the contract to be deployed
     * @param salt The salt used for the CREATE2 deployment
     * @return The predicted address where the contract will be deployed
     */
    function predictCreate2Address(
        bytes memory bytecode,
        bytes32 salt
    ) public view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(create2Factory),
                            salt,
                            keccak256(bytecode)
                        )
                    )
                )
            )
        );
    }

    /**
     * @notice Deploys a contract using CREATE2
     * @param bytecode The bytecode of the contract to deploy
     * @param salt The salt used for the CREATE2 deployment
     * @return deployedContract The address of the deployed contract
     */
    function deployWithCreate2(
        bytes memory bytecode,
        bytes32 salt
    ) external returns (address deployedContract) {
        // Calculate the contract address that will be deployed
        deployedContract = predictCreate2Address(bytecode, salt);
        console.log("Predicted address:", deployedContract);
        console.log("Salt (hex):", vm.toString(salt));
        console.log("Bytecode length:", bytecode.length);

        // Check if contract is already deployed
        if (this.isDeployed(deployedContract)) {
            console.log(
                "Contract already deployed at address:",
                deployedContract
            );
            return deployedContract;
        }

        // Deploy the contract if not already deployed
        address justDeployedAddr = create2Factory.deploy(bytecode, salt);
        console.log("Actually deployed at:", justDeployedAddr);
        
        // Double-check the prediction with the same inputs
        address doubleCheckPrediction = predictCreate2Address(bytecode, salt);
        console.log("Double-check prediction:", doubleCheckPrediction);
        
        require(
            deployedContract == justDeployedAddr,
            "Expected address does not match the deployed address"
        );
        require(this.isDeployed(deployedContract), "Contract did not get deployed");

        return deployedContract;
    }

    /**
     * @notice Deploys the Portal contract using CREATE3
     * @param sender The sender address
     * @param salt The salt used for the CREATE3 deployment
     * @return portal The address of the deployed Portal contract
     */
    function deployPortal(address sender, bytes32 salt) external returns (address portal) {
        bytes memory portalBytecode = vm.getDeployedCode("Portal.sol:Portal");
        console.log("Portal bytecode length:", portalBytecode.length);
        portal = this.deployWithCreate2(
            portalBytecode,
            this.getContractSalt(salt, "PORTAL")
        );
        console.log("Portal deployed at:", portal);
    }

    /**
     * @notice Deploys the Portal contract using CREATE2 with environment variable salt
     * @return portal The address of the deployed Portal contract
     */
    function deployPortalWithEnvSalt() external returns (address portal) {
        bytes32 salt = vm.envBytes32("SALT");
        return this.deployPortal(msg.sender, salt);
    }

    /**
     * @notice Main run function for deploying Portal
     */
    function run() external {
        vm.startBroadcast();
        address portal = this.deployPortalWithEnvSalt();
        console.log("Portal deployed at:", portal);
        vm.stopBroadcast();
    }
} 