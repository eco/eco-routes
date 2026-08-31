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
 * @dev ONE chainer per chain, serving every Portal. The Portal is a field of `Order`, not a constructor
 *      argument, so nothing environment-specific is baked in. CREATE3
 *      derives the address from (deployer, salt) alone, so the chainer lands at the SAME address on every
 *      chain even where the Portal differs. That matters here more than usual: a chained order names the
 *      chainer inside `intent1.route.calls[k].target`, which is covered by intent1's hash, so an SDK that
 *      builds orders for several source chains wants one address to hard-code rather than a per-chain table.
 *
 * @dev Bump CHAINER_VERSION whenever the {IntentChainer.Order} ABI changes.
 *      CREATE3 ignores bytecode when deriving the address, so without a salt bump a new ABI would land on
 *      top of the old address and orders committed against the old shape would decode into the new one.
 *
 * @dev Usage:
 *      PRIVATE_KEY=0x... SALT=0x... forge script \
 *        scripts/DeployIntentChainer.s.sol --rpc-url <RPC_URL> --broadcast --slow
 *
 *      To predict the address without deploying:
 *      PRIVATE_KEY=0x... SALT=0x... forge script \
 *        scripts/DeployIntentChainer.s.sol --sig "predictAddress()" --rpc-url <RPC_URL>
 */
contract DeployIntentChainer is Script {
    ICreate3Deployer constant create3Deployer =
        ICreate3Deployer(0xC6BAd1EbAF366288dA6FB5689119eDd695a66814);

    /// @dev Salt discriminator. Bump on any `Order` ABI change.
    ///      V1 pinned the Portal as a constructor immutable, which made the contract per-environment and
    ///      got deployed against the ephemeral Portal by mistake. V2 moves the Portal into `Order`, so one
    ///      deployment serves every Portal and there is no deploy-time binding left to get wrong.
    string constant CHAINER_VERSION = "INTENT_CHAINER_V3";

    function run() external {
        bytes32 rootSalt = vm.envBytes32("SALT");
        address deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));

        bytes32 salt = _contractSalt(rootSalt, CHAINER_VERSION);

        // No constructor arguments: the Portal is named per order, not per deployment.
        bytes memory bytecode = type(IntentChainer).creationCode;

        address predicted = create3Deployer.deployedAddress(
            bytes(""),
            deployer,
            salt
        );

        console.log("Chain ID       :", block.chainid);
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

        console.log("Deployed with no constructor binding");
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
