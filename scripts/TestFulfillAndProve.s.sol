// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "../contracts/types/Intent.sol";

interface IPortal {
    function fulfillAndProve(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        address prover,
        uint64 sourceChainDomainID,
        bytes memory data
    ) external payable returns (bytes[] memory);
}

contract TestFulfillAndProve is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address portal = 0x399Dbd5DF04f83103F77A58cBa2B7c4d3cdede97;

        vm.startBroadcast(deployerPrivateKey);

        // Create the route with 0.1 RON nativeAmount, no calls
        Route memory route = Route({
            salt: bytes32(uint256(2)),  // Changed salt to create new intent
            deadline: 1795071021,  // ~1 year from now
            portal: portal,
            nativeAmount: 0.1 ether,
            tokens: new TokenAmount[](0),
            calls: new Call[](0)
        });

        // Compute the intent hash
        bytes32 rewardHash = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
        uint64 destination = 2020;  // Ronin chain where intent is being fulfilled
        bytes32 routeHash = keccak256(abi.encode(route));
        bytes32 intentHash = keccak256(abi.encodePacked(destination, routeHash, rewardHash));

        // Other intent parameters
        bytes32 claimant = bytes32(uint256(uint160(0xFfe05Fc55F42a9AE9Eb97731C1cA1E0AA9030FdE)));
        address prover = 0xda1513e4BD479AF7Ac192FAc101dD94A7F6F9c0b;
        uint64 sourceChainDomainID = 15971525489660198786;  // Base CCIP selector
        bytes memory data = abi.encode(
            address(0xda1513e4BD479AF7Ac192FAc101dD94A7F6F9c0b),  // sourceChainProver
            uint256(300000),  // gasLimit
            false  // allowOutOfOrderExecution
        );

        console.log("Calling fulfillAndProve on portal:", portal);
        console.log("Route hash:", vm.toString(routeHash));
        console.log("Reward hash:", vm.toString(rewardHash));
        console.log("Intent hash:", vm.toString(intentHash));
        console.log("Sending 1 RON as msg.value (0.1 for native transfer + CCIP fee)");

        IPortal(portal).fulfillAndProve{value: 1 ether}(
            intentHash,
            route,
            rewardHash,
            claimant,
            prover,
            sourceChainDomainID,
            data
        );

        console.log("Success!");

        vm.stopBroadcast();
    }
}
