// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {ICreate3Deployer} from "../contracts/tools/ICreate3Deployer.sol";
import {DepositFactory_CCTPMint_GatewayERC20} from "../contracts/deposit/DepositFactory_CCTPMint_GatewayERC20.sol";

/**
 * @title DeployGatewayERC20Factory
 * @notice Deploys DepositFactory_CCTPMint_GatewayERC20 to multiple chains using CREATE3
 *         for deterministic same-address deployment despite different constructor args per chain.
 *
 * @dev Usage:
 *      PRIVATE_KEY=0x... SALT=0x... SOURCE_TOKEN=0x... forge script \
 *        scripts/DeployGatewayERC20Factory.s.sol --rpc-url <RPC_URL> --broadcast --slow
 *
 *      To predict the address without deploying:
 *      PRIVATE_KEY=0x... SALT=0x... forge script \
 *        scripts/DeployGatewayERC20Factory.s.sol --sig "predictAddress()" --rpc-url <RPC_URL>
 */
contract DeployGatewayERC20Factory is Script {
    ICreate3Deployer constant create3Deployer =
        ICreate3Deployer(0xC6BAd1EbAF366288dA6FB5689119eDd695a66814);

    // ── Shared (same on all chains) ──────────────────────────────────
    address constant PORTAL_ADDRESS = 0x399Dbd5DF04f83103F77A58cBa2B7c4d3cdede97;
    address constant LOCAL_PROVER = 0x929aB8DeC1c1C383391A4271218be5d867a3Bb6e;
    address constant CCTP_TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    uint64  constant INTENT_DEADLINE_DURATION = 14400; // 4 hours

    // ── Destination: Polygon ─────────────────────────────────────────
    uint32  constant DESTINATION_DOMAIN = 7;       // CCTP domain for Polygon
    uint64  constant DESTINATION_CHAIN_ID = 137;
    address constant DESTINATION_PROVER = 0x929aB8DeC1c1C383391A4271218be5d867a3Bb6e;
    address constant DESTINATION_USDC = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;
    address constant GATEWAY_ADDRESS = 0x77777777Dcc4d5A8B6E418Fd04D8997ef11000eE;
    uint256 constant MAX_FEE_BPS = 13; // 1.3 bps

    function run() external {
        address sourceToken = vm.envAddress("SOURCE_TOKEN");
        bytes32 rootSalt = vm.envBytes32("SALT");
        address deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));

        bytes32 salt = _contractSalt(rootSalt, "GATEWAY_ERC20_FACTORY_V2");

        // Build creation bytecode (creationCode + abi-encoded constructor args)
        bytes memory bytecode = abi.encodePacked(
            type(DepositFactory_CCTPMint_GatewayERC20).creationCode,
            abi.encode(
                sourceToken,
                PORTAL_ADDRESS,
                LOCAL_PROVER,
                INTENT_DEADLINE_DURATION,
                DESTINATION_DOMAIN,
                CCTP_TOKEN_MESSENGER,
                DESTINATION_CHAIN_ID,
                DESTINATION_PROVER,
                DESTINATION_USDC,
                GATEWAY_ADDRESS,
                MAX_FEE_BPS
            )
        );

        // Predict address (same on every chain — CREATE3 ignores bytecode)
        address predicted = create3Deployer.deployedAddress(
            bytes(""), // bytecode not used for address prediction in CREATE3
            deployer,
            salt
        );

        console.log("Chain ID       :", block.chainid);
        console.log("Source Token   :", sourceToken);
        console.log("Predicted addr :", predicted);

        // Check if already deployed
        if (predicted.code.length > 0) {
            console.log("Already deployed at:", predicted);
            return;
        }

        vm.startBroadcast(deployer);

        address deployed = create3Deployer.deploy(bytecode, salt);
        require(deployed == predicted, "Address mismatch");
        require(deployed.code.length > 0, "Deployment failed");

        vm.stopBroadcast();

        console.log("Deployed at    :", deployed);

        // Verify configuration
        DepositFactory_CCTPMint_GatewayERC20 factory = DepositFactory_CCTPMint_GatewayERC20(deployed);
        (
            address _sourceToken,
            address _portalAddress,
            ,
            ,
            ,
            ,
            uint64 _destChainId,
            ,
            ,
            address _gateway,
        ) = factory.getConfiguration();

        require(_sourceToken == sourceToken, "sourceToken mismatch");
        require(_portalAddress == PORTAL_ADDRESS, "portal mismatch");
        require(_destChainId == DESTINATION_CHAIN_ID, "destChainId mismatch");
        require(_gateway == GATEWAY_ADDRESS, "gateway mismatch");

        console.log("Configuration verified");
    }

    /// @notice Predict the factory address without deploying (dry-run)
    function predictAddress() external {
        bytes32 rootSalt = vm.envBytes32("SALT");
        address deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        bytes32 salt = _contractSalt(rootSalt, "GATEWAY_ERC20_FACTORY_V2");

        address predicted = create3Deployer.deployedAddress(
            bytes(""),
            deployer,
            salt
        );

        console.log("Predicted factory address:", predicted);
        console.log("Already deployed:", predicted.code.length > 0);
    }

    function _contractSalt(
        bytes32 rootSalt,
        string memory contractName
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(rootSalt, keccak256(abi.encodePacked(contractName))));
    }
}
