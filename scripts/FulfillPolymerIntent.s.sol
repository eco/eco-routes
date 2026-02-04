// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {Portal} from "../contracts/Portal.sol";
import {Route, Reward, TokenAmount, Call} from "../contracts/types/Intent.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title FulfillPolymerIntent
 * @notice Script to construct an intent offchain and call fulfillAndProve
 *
 * Addresses extracted from existing scripts:
 * - Portal: 0x399Dbd5DF04f83103F77A58cBa2B7c4d3cdede97
 * - PolymerProver: 0xCf05B59f445a0Bb49061B1919bA3c7577034cC6F
 * - USDT (Mainnet): 0xdAC17F958D2ee523a2206206994597C13D831ec7
 */
contract FulfillPolymerIntent is Script {
    // Contract addresses
    address constant PORTAL = 0x399Dbd5DF04f83103F77A58cBa2B7c4d3cdede97;
    address constant POLYMER_PROVER =
        0xCf05B59f445a0Bb49061B1919bA3c7577034cC6F;

    // Token addresses
    address constant USDT_MAINNET = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // Fresh recipient wallet (generated with cast wallet new)
    address constant RECIPIENT = 0x63Ce28aff26d8e7201D8f3de0A723FeaE613F069;

    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        uint256 amount = 100000; // 0.1 USDT (6 decimals)
        uint64 deadline = uint64(block.timestamp + 1 days);

        console.log("=== Fulfill Polymer Intent ===");
        console.log("Deployer:", deployer);
        console.log("Recipient:", RECIPIENT);
        console.log("Portal:", PORTAL);
        console.log("PolymerProver:", POLYMER_PROVER);
        console.log("Amount: 0.1 USDT");

        // Construct route: transfer 0.1 USDT to fresh recipient wallet
        Route memory route = Route({
            salt: bytes32(uint256(456)), // Changed salt for new intent
            deadline: deadline,
            portal: PORTAL,
            nativeAmount: 0,
            tokens: new TokenAmount[](1),
            calls: new Call[](1)
        });

        route.tokens[0] = TokenAmount({token: USDT_MAINNET, amount: amount});

        route.calls[0] = Call({
            target: USDT_MAINNET,
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                RECIPIENT,
                amount
            ),
            value: 0
        });

        // Construct reward: 0 rewards
        Reward memory reward = Reward({
            deadline: deadline,
            creator: deployer,
            prover: POLYMER_PROVER,
            nativeAmount: 0,
            tokens: new TokenAmount[](0) // No reward tokens
        });

        // Compute intent hash
        bytes32 routeHash = keccak256(abi.encode(route));
        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(uint64(1), routeHash, rewardHash)
        ); // destination = 1 (Mainnet)
        bytes32 claimantBytes = bytes32(uint256(uint160(deployer)));

        console.log("Route hash:", vm.toString(routeHash));
        console.log("Reward hash:", vm.toString(rewardHash));
        console.log("Intent hash:", vm.toString(intentHash));

        vm.startBroadcast(privateKey);

        // Check current allowance
        uint256 currentAllowance = IERC20(USDT_MAINNET).allowance(
            deployer,
            PORTAL
        );
        console.log("Current USDT allowance:", currentAllowance);

        // Only approve if needed
        if (currentAllowance < amount) {
            // USDT requires resetting allowance to 0 before approving a new amount
            if (currentAllowance > 0) {
                IERC20(USDT_MAINNET).approve(PORTAL, 0);
            }
            IERC20(USDT_MAINNET).approve(PORTAL, amount);
            console.log("Approved Portal to spend", amount, "USDT");
        } else {
            console.log("Allowance already sufficient");
        }

        // Fulfill and prove
        // Note: PolymerProver doesn't use the data parameter (marked as unused in contract)
        Portal(PORTAL).fulfillAndProve(
            intentHash,
            route,
            rewardHash,
            claimantBytes,
            POLYMER_PROVER,
            8453, // Source chain ID (Base) - Polymer uses actual chain IDs, not custom domain IDs
            "" // Empty bytes - data parameter is unused by PolymerProver
        );

        console.log("Successfully called fulfillAndProve!");

        vm.stopBroadcast();
    }
}
