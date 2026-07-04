/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PortalCore} from "./PortalCore.sol";
import {AccountDeployer} from "./account/AccountDeployer.sol";
import {Account} from "./account/Account.sol";

/**
 * @title Portal
 * @notice Portal contract combining IntentSource and Inbox functionality
 * @dev Main entry point for intent publishing, fulfillment, and proving. The combined-half logic
 *      (same-chain {PortalCore-fulfillAndSettle}) lives in {PortalCore}; this contract only supplies the
 *      shared {AccountDeployer} constructor args (the Account clone template + CREATE2 prefix) via C3
 *      linearization.
 */
contract Portal is PortalCore {
    /**
     * @notice Initializes the Portal contract
     * @dev Creates a unified entry point combining source and destination chain functionality
     */
    constructor() AccountDeployer(address(new Account()), bytes1(0xff)) {}
}
