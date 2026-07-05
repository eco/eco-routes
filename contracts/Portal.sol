/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PortalCore} from "./PortalCore.sol";
import {AccountDeployer} from "./account/AccountDeployer.sol";

/**
 * @title Portal
 * @notice Portal IMPLEMENTATION combining IntentSource and Inbox functionality
 * @dev A versioned implementation that runs behind the permanent {PortalProxy} (PR9): the proxy
 *      `delegatecall`s into it, so `address(this)` in this contract is always the PROXY. The combined-half
 *      logic (same-chain {PortalCore-fulfillAndSettle}) lives in {PortalCore}; this contract only supplies
 *      the shared {AccountDeployer} constructor args (the Account clone template + CREATE2 prefix) via C3
 *      linearization. The Account clone template is passed in (a SINGLE shared {Account} implementation,
 *      bound to the proxy) rather than deployed here, so every registered Portal version derives the SAME
 *      per-intent Account addresses.
 */
contract Portal is PortalCore {
    /**
     * @notice Wires the shared Account clone template.
     * @param accountImplementation The shared {Account} implementation (bound to the proxy) that
     *        per-intent clones delegate to.
     */
    constructor(
        address accountImplementation
    ) AccountDeployer(accountImplementation, bytes1(0xff)) {}
}
