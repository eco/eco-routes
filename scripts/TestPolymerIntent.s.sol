// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {Portal} from "../contracts/Portal.sol";
import {PolymerProver} from "../contracts/prover/PolymerProver.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../contracts/types/Intent.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestPolymerIntent
 * @notice Script to create, fulfill, and prove intents between Base and Mainnet
 */
contract TestPolymerIntent is Script {
    // Contracts
    address constant PORTAL = 0x399Dbd5DF04f83103F77A58cBa2B7c4d3cdede97;
    address constant POLYMER_PROVER =
        0xCf05B59f445a0Bb49061B1919bA3c7577034cC6F;

    // Tokens
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant USDT_BASE = 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2;
    address constant USDC_MAINNET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT_MAINNET = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // Fresh EOA addresses (generated via cast wallet new, verified 0 balance)
    address constant TARGET_MAINNET =
        0xe8F9F6A2AdcCB5c92dD3392C8bEB9d394fC2A50f; // Receives USDT on Mainnet (Base→Mainnet intent)
    address constant CLAIMANT_MAINNET =
        0x521670283Eb07d47DF50991AE3AB525ceA998E17; // Withdraws USDT reward on Mainnet (Mainnet→Base intent)

    /**
     * @notice Base → Mainnet: Transfer 0.1 USDT, offer 0.1 USDC reward
     */
    function baseToMainnet_create() external returns (bytes32 intentHash) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(privateKey);
        uint256 amount = 100000; // 0.1 token (6 decimals)

        console.log("=== Base -> Mainnet: Creating Intent ===");
        console.log("Transfer: 0.1 USDT on Mainnet to", TARGET_MAINNET);
        console.log("Reward: 0.1 USDC on Base");
        console.log("User:", user);

        Intent memory intent = Intent({
            destination: 1, // Mainnet
            route: Route({
                salt: bytes32(uint256(1)),
                deadline: uint64(block.timestamp + 1 days),
                portal: PORTAL,
                nativeAmount: 0,
                tokens: new TokenAmount[](1),
                calls: new Call[](1)
            }),
            reward: Reward({
                deadline: uint64(block.timestamp + 1 days),
                creator: user,
                prover: POLYMER_PROVER,
                nativeAmount: 0,
                tokens: new TokenAmount[](1)
            })
        });

        intent.route.tokens[0] = TokenAmount({
            token: USDT_MAINNET,
            amount: amount
        });
        intent.route.calls[0] = Call({
            target: USDT_MAINNET,
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                TARGET_MAINNET,
                amount
            ),
            value: 0
        });
        intent.reward.tokens[0] = TokenAmount({
            token: USDC_BASE,
            amount: amount
        });

        intentHash = keccak256(abi.encode(intent));

        vm.startBroadcast(privateKey);
        IERC20(USDC_BASE).approve(PORTAL, amount);
        Portal(PORTAL).publishAndFund(intent, false);
        vm.stopBroadcast();

        console.log("Intent created!");
        console.log("Intent hash:", vm.toString(intentHash));
        return intentHash;
    }

    /**
     * @notice Base → Mainnet: Fulfill on Mainnet
     */
    function baseToMainnet_fulfill() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        uint256 amount = 100000; // 0.1 USDT
        uint64 deadline = uint64(block.timestamp + 1 days);

        // Create simple intent: transfer USDT to deployer
        Intent memory intent = Intent({
            destination: 1, // Mainnet chain ID
            route: Route({
                salt: bytes32(uint256(777)),
                deadline: deadline,
                portal: PORTAL,
                nativeAmount: 0,
                tokens: new TokenAmount[](1),
                calls: new Call[](1)
            }),
            reward: Reward({
                deadline: deadline,
                creator: deployer,
                prover: POLYMER_PROVER,
                nativeAmount: 0,
                tokens: new TokenAmount[](0) // No reward
            })
        });

        // Route transfers USDT to deployer
        intent.route.tokens[0] = TokenAmount({
            token: USDT_MAINNET,
            amount: amount
        });
        intent.route.calls[0] = Call({
            target: USDT_MAINNET,
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                deployer,
                amount
            ),
            value: 0
        });

        // Compute intent hash correctly
        bytes32 routeHash = keccak256(abi.encode(intent.route));
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        bytes32 intentHash = keccak256(
            abi.encodePacked(uint64(1), routeHash, rewardHash)
        );
        bytes32 claimantBytes = bytes32(uint256(uint160(deployer)));

        vm.startBroadcast(privateKey);

        // Approve Portal to spend USDT
        IERC20(USDT_MAINNET).approve(PORTAL, amount);

        // Fulfill and prove
        Portal(PORTAL).fulfillAndProve(
            intentHash,
            intent.route,
            rewardHash,
            claimantBytes,
            POLYMER_PROVER,
            8453, // Source chain
            ""
        );

        vm.stopBroadcast();
    }

    /**
     * @notice Mainnet → Base: Transfer 0.1 USDC, offer 0.1 USDT reward
     */
    function mainnetToBase_create() external returns (bytes32 intentHash) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(privateKey);
        uint256 amount = 100000; // 0.1 token (6 decimals)

        console.log("=== Mainnet -> Base: Creating Intent ===");
        console.log("Transfer: 0.1 USDC on Base");
        console.log("Reward: 0.1 USDT on Mainnet");
        console.log("User:", user);

        Intent memory intent = Intent({
            destination: 8453, // Base
            route: Route({
                salt: bytes32(uint256(2)),
                deadline: uint64(block.timestamp + 1 days),
                portal: PORTAL,
                nativeAmount: 0,
                tokens: new TokenAmount[](1),
                calls: new Call[](0)
            }),
            reward: Reward({
                deadline: uint64(block.timestamp + 1 days),
                creator: user,
                prover: POLYMER_PROVER,
                nativeAmount: 0,
                tokens: new TokenAmount[](1)
            })
        });

        intent.route.tokens[0] = TokenAmount({
            token: USDC_BASE,
            amount: amount
        });
        intent.reward.tokens[0] = TokenAmount({
            token: USDT_MAINNET,
            amount: amount
        });

        intentHash = keccak256(abi.encode(intent));

        vm.startBroadcast(privateKey);
        IERC20(USDT_MAINNET).approve(PORTAL, amount);
        Portal(PORTAL).publishAndFund(intent, false);
        vm.stopBroadcast();

        console.log("Intent created!");
        console.log("Intent hash:", vm.toString(intentHash));
        return intentHash;
    }

    /**
     * @notice Mainnet → Base: Fulfill on Base
     */
    function mainnetToBase_fulfill() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address solver = vm.addr(privateKey);
        uint256 amount = 100000;

        console.log("=== Mainnet -> Base: Fulfilling on Base ===");
        console.log("Solver:", solver);
        console.log("Claimant (will withdraw on Mainnet):", CLAIMANT_MAINNET);

        Intent memory intent = Intent({
            destination: 8453,
            route: Route({
                salt: bytes32(uint256(2)),
                deadline: uint64(block.timestamp + 1 days),
                portal: PORTAL,
                nativeAmount: 0,
                tokens: new TokenAmount[](1),
                calls: new Call[](0)
            }),
            reward: Reward({
                deadline: uint64(block.timestamp + 1 days),
                creator: solver,
                prover: POLYMER_PROVER,
                nativeAmount: 0,
                tokens: new TokenAmount[](1)
            })
        });

        intent.route.tokens[0] = TokenAmount({
            token: USDC_BASE,
            amount: amount
        });
        intent.reward.tokens[0] = TokenAmount({
            token: USDT_MAINNET,
            amount: amount
        });

        bytes32 intentHash = keccak256(abi.encode(intent));
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        bytes32 claimantBytes = bytes32(uint256(uint160(CLAIMANT_MAINNET)));

        console.log("Fulfilling intent:", vm.toString(intentHash));

        vm.startBroadcast(privateKey);

        // Approve and fulfill with proof
        IERC20(USDC_BASE).approve(PORTAL, amount);
        Portal(PORTAL).fulfillAndProve(
            intentHash,
            intent.route,
            rewardHash,
            claimantBytes,
            POLYMER_PROVER,
            1, // Source chain (Mainnet)
            ""
        );
        console.log("Intent fulfilled and proven on Base!");

        vm.stopBroadcast();
    }

    /**
     * @notice Mainnet → Base: Withdraw reward on Mainnet (must be called after proof)
     */
    function mainnetToBase_withdraw() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address solver = vm.addr(privateKey);
        uint256 amount = 100000;

        console.log("=== Mainnet -> Base: Withdrawing reward on Mainnet ===");
        console.log("Claimant:", CLAIMANT_MAINNET);

        Intent memory intent = Intent({
            destination: 8453,
            route: Route({
                salt: bytes32(uint256(2)),
                deadline: uint64(block.timestamp + 1 days),
                portal: PORTAL,
                nativeAmount: 0,
                tokens: new TokenAmount[](1),
                calls: new Call[](0)
            }),
            reward: Reward({
                deadline: uint64(block.timestamp + 1 days),
                creator: solver,
                prover: POLYMER_PROVER,
                nativeAmount: 0,
                tokens: new TokenAmount[](1)
            })
        });

        intent.route.tokens[0] = TokenAmount({
            token: USDC_BASE,
            amount: amount
        });
        intent.reward.tokens[0] = TokenAmount({
            token: USDT_MAINNET,
            amount: amount
        });

        bytes32 intentHash = keccak256(abi.encode(intent));
        bytes32 routeHash = keccak256(abi.encode(intent.route));

        console.log("Intent hash:", vm.toString(intentHash));

        // Check USDT balance before
        uint256 balanceBefore = IERC20(USDT_MAINNET).balanceOf(
            CLAIMANT_MAINNET
        );
        console.log("USDT balance before:", balanceBefore);

        vm.startBroadcast(privateKey);
        Portal(PORTAL).withdraw(intent.destination, routeHash, intent.reward);
        vm.stopBroadcast();

        console.log("Reward withdrawn on Mainnet!");

        // Check USDT balance after
        uint256 balanceAfter = IERC20(USDT_MAINNET).balanceOf(CLAIMANT_MAINNET);
        console.log("USDT balance after:", balanceAfter);
    }
}
