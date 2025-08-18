// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Portal} from "../contracts/Portal.sol";
import {LayerZeroProver} from "../contracts/prover/LayerZeroProver.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../contracts/types/Intent.sol";
import {IProver} from "../contracts/interfaces/IProver.sol";
import {OptionsBuilder} from "../contracts/libs/OptionsBuilder.sol";


contract TestLayerZeroCrossChain is Script {
    using OptionsBuilder for bytes;
    // Contract addresses on Optimism - will be loaded from .env
    address public OPTIMISM_PORTAL;
    address public OPTIMISM_LAYERZERO_PROVER;
    
    // Test amount (0.0001 ETH)
    uint256 constant TEST_AMOUNT = 0.0001 ether;
    
    // Chain IDs
    uint64 constant OPTIMISM_CHAIN_ID = 10;
    uint64 constant TRON_CHAIN_ID = 728126428; // Tron mainnet chain ID
    uint64 constant TRON_ENDPOINT_ID = 30420; // LayerZero endpoint ID for Tron
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Load addresses from .env
        OPTIMISM_PORTAL = vm.envAddress("OP_PORTAL_ADDRESS");
        OPTIMISM_LAYERZERO_PROVER = vm.envAddress("OP_LAYERZERO_PROVER");
        
        console.log("Testing LayerZero Cross-Chain Flow on Optimism Mainnet");
        console.log("Deployer address:");
        console.logAddress(deployer);
        console.log("Optimism Portal address:");
        console.logAddress(OPTIMISM_PORTAL);
        console.log("Optimism LayerZero Prover address:");
        console.logAddress(OPTIMISM_LAYERZERO_PROVER);
        
        // Start broadcasting transactions to mainnet (this replaces startPrank)
        vm.startBroadcast(deployerPrivateKey);
        
        // Create test intent
        Intent memory intent = _createTestIntent(deployer);
        bytes32 intentHash = _hashIntent(intent);
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        
        console.log("Created Intent Hash:");
        console.logBytes32(intentHash);
        
        // Prepare data for LayerZero prover
        bytes32 claimantBytes32 = bytes32(uint256(uint160(deployer)));
        
        // For cross-chain testing, we use the Tron LayerZero prover address as bytes32
        // TVaUrbN3cm6xxvi4e1fc1jUhs19mbtLEd7 in Tron converts to this hex representation
        // In production, proper Tron base58 to hex conversion would be used
        bytes32 tronProverAddressBytes32 = 0x000000000000000000000000d7162ece9939b0a6ace3b143764ec00fe88b15e4;

        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        
        // Create minimal lzData with default values
        bytes memory lzData = abi.encode(
            LayerZeroProver.UnpackedData({
                sourceChainProver: tronProverAddressBytes32, // Use Tron prover address
                options: _options,
                gasLimit: 0 // Let it use default gas limit
            })
        );
        
        // Print the entire lzData object as raw bytes
        console.log("=== LZ DATA OBJECT ===");
        console.logBytes(lzData);
        console.log("=====================");
        
        console.log("=== STEP 1: Fulfilling Intent ===");
        
        Portal portal = Portal(payable(OPTIMISM_PORTAL));
        bytes[] memory result = portal.fulfill(
            intentHash,
            intent.route,
            keccak256(abi.encode(intent.reward)),
            claimantBytes32
        );
        
        console.log("Intent fulfilled successfully!");
        console.log("Execution results length:");
        console.logUint(result.length);
        
        // Check if intent was fulfilled
        bytes32 fulfilledClaimant = portal.claimants(intentHash);
        console.log("Intent fulfilled with claimant:");
        console.logBytes32(fulfilledClaimant);
        
        // Uncomment fee calculation and proving
        // Get fee for the proof - using TRON_ENDPOINT_ID as destination
        LayerZeroProver layerZeroProver = LayerZeroProver(OPTIMISM_LAYERZERO_PROVER);
        
        // Encode proofs for fee calculation
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = intentHash;
        
        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = claimantBytes32;
        
        bytes memory encodedProofs = _encodeProofs(intentHashes, claimants);
        
        uint256 fee = layerZeroProver.fetchFee(
            uint64(TRON_ENDPOINT_ID), // V2 Endpoint ID
            encodedProofs,
            lzData
        );
        
        console.log("Required fee:");
        console.logUint(fee);
        
        // Check if we have enough balance
        uint256 balance = deployer.balance;
        console.log("Wallet balance:");
        console.logUint(balance);
        
        if (balance < fee) {
            console.log("Insufficient balance for fee");
            console.log("Required:");
            console.logUint(fee);
            console.log("Available:");
            console.logUint(balance);
            vm.stopBroadcast();
            return;
        }
        
        console.log("=== STEP 2: Proving Intent ===");
        
        console.log("Calling prove with:");
        console.log("  - source chain ID:");
        console.logUint(TRON_ENDPOINT_ID);
        console.log("  - prover address:");
        console.logAddress(OPTIMISM_LAYERZERO_PROVER);
        console.log("  - intent hash:");
        console.logBytes32(intentHash);
        console.log("  - fee:");
        console.logUint(fee);
        
        // Call prove with the fee (reuse existing portal variable)
        portal.prove{value: fee}(
            OPTIMISM_LAYERZERO_PROVER,
            uint64(TRON_ENDPOINT_ID), // V2 Endpoint ID
            intentHashes,
            lzData
        );
        
        console.log("Intent proven successfully!");
        
        // Check if proof was recorded
        IProver.ProofData memory proofData = layerZeroProver.provenIntents(intentHash);
        console.log("Proof data - claimant:");
        console.logAddress(proofData.claimant);
        console.log("Proof data - destination:");
        console.logUint(proofData.destination);
        
        console.log("LayerZero cross-chain test completed!");
        console.log("Next steps:");
        console.log("1. Check LayerZero scan for the cross-chain message");
        console.log("2. Verify the proof was received on Tron manually");
        console.log("3. Check the LayerZeroProver contract on Tron for the recorded proof");
        
        // Stop broadcasting transactions
        vm.stopBroadcast();
    }
    
    function _createTestIntent(address deployer) internal view returns (Intent memory) {
        // Create route tokens (empty for ETH transfer)
        TokenAmount[] memory routeTokens = new TokenAmount[](0);
        
        // Create calls (send 0 ETH to deployer)
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: deployer,
            data: "",
            value: 0 // Send 0 ETH to deployer
        });
        
        // Create reward tokens (empty for this test)
        TokenAmount[] memory rewardTokens = new TokenAmount[](0);
        
        // Create route
        Route memory route = Route({
            salt: keccak256(abi.encodePacked("test-salt-", block.timestamp)),
            deadline: uint64(block.timestamp + 3600000),
            portal: OPTIMISM_PORTAL,
            tokens: routeTokens,
            calls: calls
        });
        
        // Create reward
        Reward memory reward = Reward({
            deadline: uint64(block.timestamp + 3600),
            creator: deployer,
            prover: OPTIMISM_LAYERZERO_PROVER,
            nativeAmount: 0,
            tokens: rewardTokens
        });
        
        return Intent({
            destination: OPTIMISM_CHAIN_ID,
            route: route,
            reward: reward
        });
    }
    
    function _hashIntent(Intent memory _intent) internal pure returns (bytes32) {
        bytes32 routeHash = keccak256(abi.encode(_intent.route));
        bytes32 rewardHash = keccak256(abi.encode(_intent.reward));
        return keccak256(abi.encodePacked(_intent.destination, routeHash, rewardHash));
    }

    function _encodeProofs(
        bytes32[] memory intentHashes,
        bytes32[] memory claimants
    ) internal pure returns (bytes memory encodedProofs) {
        require(
            intentHashes.length == claimants.length,
            "Array length mismatch"
        );

        encodedProofs = new bytes(intentHashes.length * 64);
        for (uint256 i = 0; i < intentHashes.length; i++) {
            assembly {
                let offset := mul(i, 64)
                // Store hash in first 32 bytes of each pair
                mstore(
                    add(add(encodedProofs, 0x20), offset),
                    mload(add(intentHashes, add(0x20, mul(i, 32))))
                )
                // Store claimant in next 32 bytes of each pair
                mstore(
                    add(add(encodedProofs, 0x20), add(offset, 32)),
                    mload(add(claimants, add(0x20, mul(i, 32))))
                )
            }
        }
    }
} 