/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Reward} from "../types/Intent.sol";

import {BaseVault} from "./BaseVault.sol";

/**
 * @title Vault
 * @notice A self-destructing contract that handles reward distribution for intents
 * @dev Created by IntentSource for each intent, handles token and native currency transfers,
 * then self-destructs after distributing rewards
 */
contract VaultImplementation is BaseVault {
    /**
     * @notice Creates and immediately executes reward distribution
     * @dev This function is delegated to by the VaultProxy contract
     * @param intentHash The hash of the intent being processed
     * @param reward The reward structure containing native and token rewards
     * @dev The function will self-destruct after processing the rewards
     */
    function operate(
        bytes32 intentHash,
        uint64 destination,
        bytes32 routeHash,
        Reward memory reward
    ) external payable {
        require(
            intentHash ==
                keccak256(
                    abi.encodePacked(destination, routeHash, abi.encode(reward))
                ),
            InvalidIntentHash(
                intentHash,
                keccak256(
                    abi.encodePacked(destination, routeHash, abi.encode(reward))
                )
            )
        );

        _run(intentHash, reward);
    }
}
