// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../contracts/types/Intent.sol";

contract ComputeIntentHash is Script {
    function run() external view {
        address portal = 0x399Dbd5DF04f83103F77A58cBa2B7c4d3cdede97;

        // Create a call to transfer 0.1 RON to the claimant
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: 0xFfe05Fc55F42a9AE9Eb97731C1cA1E0AA9030FdE, // claimant
            value: 0.1 ether,
            data: ""
        });

        // Create the route
        Route memory route = Route({
            salt: bytes32(uint256(1)),
            deadline: 1795071021, // ~1 year from now
            portal: portal,
            nativeAmount: 0,
            tokens: new TokenAmount[](0),
            calls: calls
        });

        bytes32 rewardHash = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
        uint256 baseChainId = 8453; // Base chain where intent originated

        bytes32 routeHash = keccak256(abi.encode(route));
        bytes32 intentHash = keccak256(
            abi.encodePacked(baseChainId, routeHash, rewardHash)
        );

        console.log("Route details:");
        console.log("  salt:", vm.toString(route.salt));
        console.log("  deadline:", route.deadline);
        console.log("  portal:", route.portal);
        console.log("  nativeAmount:", route.nativeAmount);
        console.log("  tokens length:", route.tokens.length);
        console.log("  calls length:", route.calls.length);
        console.log("  call[0].target:", route.calls[0].target);
        console.log("  call[0].value:", route.calls[0].value);
        console.log("  call[0].data:", vm.toString(route.calls[0].data));
        console.log("");
        console.log("Computed hashes:");
        console.log("  routeHash:", vm.toString(routeHash));
        console.log("  rewardHash:", vm.toString(rewardHash));
        console.log("  intentHash:", vm.toString(intentHash));
    }
}
