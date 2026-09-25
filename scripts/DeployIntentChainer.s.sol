// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* solhint-disable no-console */

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
 * @dev Bump CHAINER_VERSION whenever the deployed implementation changes. CREATE3 ignores bytecode
 *      when deriving the address; the same salt cannot deploy the new implementation over an old one.
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
    ICreate3Deployer internal constant CREATE3_DEPLOYER =
        ICreate3Deployer(0xC6BAd1EbAF366288dA6FB5689119eDd695a66814);

    /// @dev Salt discriminator. Bump on any implementation change.
    ///      V1 pinned the Portal as a constructor immutable, which made the contract per-environment and
    ///      got deployed against the ephemeral Portal by mistake. V2 moves the Portal into `Order`, so one
    ///      deployment serves every Portal and there is no deploy-time binding left to get wrong.
    ///      V3 adds the committed publish flag. V4 replaces amount-only slots with typed templates and
    ///      dependency-first remote vault derivation. This changes the unshipped chainer's Order ABI.
    ///      V5 permits prefunded child vaults, extracts output calculation, and rejects codeless Portals.
    string internal constant CHAINER_VERSION = "INTENT_CHAINER_V5";

    function run() external {
        _preflight();
        bytes32 rootSalt = vm.envBytes32("SALT");
        address deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));

        bytes32 salt = _contractSalt(rootSalt, CHAINER_VERSION);

        // No constructor arguments: the Portal is named per order, not per deployment.
        bytes memory bytecode = type(IntentChainer).creationCode;

        address predicted = CREATE3_DEPLOYER.deployedAddress(
            bytes(""),
            deployer,
            salt
        );

        console.log("Chain ID       :", block.chainid);
        console.log("Predicted addr :", predicted);

        if (predicted.code.length > 0) {
            _verifyDeployment(predicted);
            console.log("Already deployed and verified at:", predicted);
            return;
        }

        vm.startBroadcast(deployer);

        address deployed = CREATE3_DEPLOYER.deploy(bytecode, salt);
        require(deployed == predicted, "Address mismatch");
        _verifyDeployment(deployed);

        vm.stopBroadcast();

        console.log("Deployed at    :", deployed);

        console.log("Deployed with no constructor binding");
    }

    /// @notice Predict the chainer address without deploying (dry-run).
    function predictAddress() external {
        _preflight();
        bytes32 rootSalt = vm.envBytes32("SALT");
        address deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        bytes32 salt = _contractSalt(rootSalt, CHAINER_VERSION);

        address predicted = CREATE3_DEPLOYER.deployedAddress(
            bytes(""),
            deployer,
            salt
        );

        if (predicted.code.length > 0) _verifyDeployment(predicted);

        console.log("Chain ID       :", block.chainid);
        console.log("Predicted addr :", predicted);
        console.log("Deployed       :", predicted.code.length > 0);
    }

    /// @notice Verify the predicted address after broadcasting, using a fresh RPC view.
    function verifyAddress() external {
        _preflight();
        address deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        bytes32 salt = _contractSalt(vm.envBytes32("SALT"), CHAINER_VERSION);
        address predicted = CREATE3_DEPLOYER.deployedAddress(
            bytes(""),
            deployer,
            salt
        );
        _verifyDeployment(predicted);
        console.log("Verified at    :", predicted);
    }

    /// @dev The shell runner binds each RPC to its requested chain ID. No Portal is assumed.
    function _preflight() internal view {
        require(
            block.chainid == vm.envOr("EXPECTED_CHAIN_ID", block.chainid),
            "Unexpected chain ID"
        );
        require(
            address(CREATE3_DEPLOYER).code.length > 0,
            "CREATE3 deployer missing"
        );
        require(
            sha256("abc") ==
                0xba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad,
            "SHA-256 precompile unavailable"
        );
        (bool success, bytes memory output) = address(0x05).staticcall(
            abi.encode(
                uint256(32),
                uint256(32),
                uint256(32),
                uint256(2),
                uint256(5),
                uint256(17)
            )
        );
        require(
            success &&
                output.length == 32 &&
                abi.decode(output, (uint256)) == 15,
            "MODEXP precompile unavailable"
        );
    }

    function _verifyDeployment(address deployed) internal view {
        require(
            deployed.codehash == keccak256(type(IntentChainer).runtimeCode),
            "IntentChainer runtime mismatch"
        );
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
