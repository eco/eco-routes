/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Semver} from "./libs/Semver.sol";

import {IntentSource} from "./IntentSource.sol";
import {Inbox} from "./Inbox.sol";
import {AccountDeployer} from "./account/AccountDeployer.sol";
import {Account} from "./account/Account.sol";

/**
 * @title Portal
 * @notice Portal contract combining IntentSource and Inbox functionality
 * @dev Main entry point for intent publishing, fulfillment, and proving. Both halves inherit the shared
 *      {AccountDeployer}, whose constructor args (the Account clone template + CREATE2 prefix) are
 *      supplied here once via C3 linearization.
 */
contract Portal is IntentSource, Inbox, Semver {
    /**
     * @notice Initializes the Portal contract
     * @dev Creates a unified entry point combining source and destination chain functionality
     */
    constructor() AccountDeployer(address(new Account()), bytes1(0xff)) {}
}
