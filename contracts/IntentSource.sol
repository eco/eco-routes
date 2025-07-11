/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Semver} from "./libs/Semver.sol";

import {UniversalSource} from "./source/UniversalSource.sol";

/**
 * @title IntentSource
 * @notice Source chain contract for the Eco Protocol's intent system
 * @dev UniversalSource inherits from EvmSource, providing both EVM and cross-chain functionality
 *      On EVM chains, this is the main entry point for interacting with intents
 */
contract IntentSource is UniversalSource, Semver {
    constructor() {}
}
