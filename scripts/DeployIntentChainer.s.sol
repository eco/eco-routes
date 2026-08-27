// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {ICreate3Deployer} from "../contracts/tools/ICreate3Deployer.sol";
import {IntentChainer} from "../contracts/chain/IntentChainer.sol";

/**
 * @title DeployIntentChainer
 * @notice Deploys the {IntentChainer} singleton to one or more chains using CREATE3.
 *
 * @dev One chainer per Portal per chain. The Portal address is the only constructor argument, and CREATE3
 *      derives the address from (deployer, salt) alone, so the chainer lands at the SAME address on every
 *      chain even where the Portal differs. That matters here more than usual: a chained order names the
 *      chainer inside `intent1.route.calls[k].target`, which is covered by intent1's hash, so an SDK that
 *      builds orders for several source chains wants one address to hard-code rather than a per-chain table.
 *
 * @dev Bump CHAINER_VERSION whenever the constructor signature or the {IntentChainer.Order} ABI changes.
 *      CREATE3 ignores bytecode when deriving the address, so without a salt bump a new ABI would land on
 *      top of the old address and orders committed against the old shape would decode into the new one.
 *
 * @dev Usage:
 *      PRIVATE_KEY=0x... SALT=0x... PORTAL=0x... forge script \
 *        scripts/DeployIntentChainer.s.sol --rpc-url <RPC_URL> --broadcast --slow
 *
 *      To predict the address without deploying:
 *      PRIVATE_KEY=0x... SALT=0x... forge script \
 *        scripts/DeployIntentChainer.s.sol --sig "predictAddress()" --rpc-url <RPC_URL>
 */
contract DeployIntentChainer is Script {
    ICreate3Deployer constant create3Deployer =
        ICreate3Deployer(0xC6BAd1EbAF366288dA6FB5689119eDd695a66814);

    /// @dev Salt discriminator. Bump on any constructor or Order ABI change.
    string constant CHAINER_VERSION = "INTENT_CHAINER_V1";

    function run() external {
        address portal = vm.envAddress("PORTAL");
        bytes32 rootSalt = vm.envBytes32("SALT");
        address deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));

        bytes32 salt = _contractSalt(rootSalt, CHAINER_VERSION);

        bytes memory bytecode = abi.encodePacked(
            type(IntentChainer).creationCode,
            abi.encode(portal)
        );

        address predicted = create3Deployer.deployedAddress(
            bytes(""),
            deployer,
            salt
        );

        console.log("Chain ID       :", block.chainid);
        console.log("Portal         :", portal);
        console.log("Predicted addr :", predicted);

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

        // A chainer bound to the wrong Portal would publish into a Portal whose Executor never calls it,
        // stranding every order built against this address. Verify before anyone commits an order to it.
        require(
            address(IntentChainer(deployed).PORTAL()) == portal,
            "portal mismatch"
        );

        console.log("Configuration verified");
    }

    /// @notice Predict the chainer address without deploying (dry-run).
    function predictAddress() external {
        bytes32 rootSalt = vm.envBytes32("SALT");
        address deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        bytes32 salt = _contractSalt(rootSalt, CHAINER_VERSION);

        address predicted = create3Deployer.deployedAddress(
            bytes(""),
            deployer,
            salt
        );

        console.log("Chain ID       :", block.chainid);
        console.log("Predicted addr :", predicted);
        console.log("Deployed       :", predicted.code.length > 0);
    }

    /// @notice Derive a per-contract salt from the root salt, matching the repo's CREATE3 convention.
    function _contractSalt(
        bytes32 rootSalt,
        string memory contractName
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(rootSalt, keccak256(abi.encodePacked(contractName)))
            );
    }
}
