/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IIntentSource} from "./interfaces/IIntentSource.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IPermit} from "./interfaces/IPermit.sol";

import {Reward} from "./types/Intent.sol";
import {BaseVault} from "./vault/BaseVault.sol";

/**
 * @title Vault
 * @notice A self-destructing contract that handles reward distribution for intents
 * @dev Created by IntentSource for each intent, handles token and native currency transfers,
 * then self-destructs after distributing rewards
 */
contract Vault is BaseVault {
    /**
     * @notice Creates and immediately executes reward distribution
     * @dev Contract self-destructs after execution
     */
    constructor(bytes32 intentHash, Reward memory reward) {
        _run(intentHash, reward);
    }
}
