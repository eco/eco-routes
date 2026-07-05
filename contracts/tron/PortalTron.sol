/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PortalCore} from "../PortalCore.sol";
import {AccountDeployer} from "../account/AccountDeployer.sol";

/**
 * @title PortalTron
 * @notice Portal IMPLEMENTATION variant for Tron chains. Combines IntentSource and Inbox functionality.
 * @dev Uses an {AccountTron} clone template (via the 0x41 CREATE2 prefix) to support non-standard ERC20
 *      tokens such as Tron USDT. Identical to {Portal} apart from the Account clone template (a shared
 *      {AccountTron} implementation bound to the proxy, passed in) and the CREATE2 prefix supplied to the
 *      shared {AccountDeployer}. Runs behind the permanent {PortalProxy} (PR9).
 */
contract PortalTron is PortalCore {
    /**
     * @notice Wires the shared AccountTron clone template and the ERC-7683 adapter implementation.
     * @param accountImplementation The shared {AccountTron} implementation (bound to the proxy) that
     *        per-intent clones delegate to.
     * @param erc7683Implementation The {ERC7683Implementation} the lean Portal delegates its ERC-7683
     *        surface to via {PortalCore-fallback} (a SINGLE shared adapter serves both EVM and TRON — it
     *        holds no account-derivation state, so it needs no TRON-specific variant).
     */
    constructor(
        address accountImplementation,
        address erc7683Implementation
    )
        AccountDeployer(accountImplementation, bytes1(0x41))
        PortalCore(erc7683Implementation)
    {}
}
