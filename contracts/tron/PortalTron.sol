/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Semver} from "../libs/Semver.sol";
import {IntentSource} from "../IntentSource.sol";
import {Inbox} from "../Inbox.sol";
import {AccountDeployer} from "../account/AccountDeployer.sol";
import {AccountTron} from "./AccountTron.sol";

/**
 * @title PortalTron
 * @notice Portal variant for Tron chains. Combines IntentSource and Inbox functionality.
 * @dev Uses AccountTron clones (via the 0x41 CREATE2 prefix) to support non-standard ERC20
 *      tokens such as Tron USDT. Identical to {Portal} apart from the Account clone template and the
 *      CREATE2 prefix supplied to the shared {AccountDeployer}.
 */
contract PortalTron is IntentSource, Inbox, Semver {
    constructor() AccountDeployer(address(new AccountTron()), bytes1(0x41)) {}
}
