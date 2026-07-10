/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Semver} from "./libs/Semver.sol";
import {IntentSource} from "./IntentSource.sol";
import {Inbox} from "./Inbox.sol";
import {VaultTron} from "./vault/VaultTron.sol";

/**
 * @title PortalTron
 * @notice Portal variant for Tron chains. Combines IntentSource and Inbox functionality.
 * @dev Uses VaultTron clones (via the 0x41 CREATE2 prefix) to support non-standard ERC20
 *      tokens such as Tron USDT.
 */
contract PortalTron is IntentSource, Inbox, Semver {
    /**
     * @notice Initializes the PortalTron contract
     * @param nativeErc20 ERC20 token address aliased to this deployment's native asset, or
     *        `address(0)` if none. See {IntentSource-NATIVE_ERC20}.
     */
    constructor(
        address nativeErc20
    ) IntentSource(address(new VaultTron()), bytes1(0x41), nativeErc20) {}
}
