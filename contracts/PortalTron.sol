/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Semver} from "./libs/Semver.sol";
import {IntentSourceTron} from "./IntentSourceTron.sol";
import {Inbox} from "./Inbox.sol";

/**
 * @title PortalTron
 * @notice Portal variant for Tron chains. Combines IntentSourceTron and Inbox functionality.
 * @dev Identical to Portal except it uses VaultTron clones (via IntentSourceTron) to support
 *      non-standard ERC20 tokens such as Tron USDT.
 */
contract PortalTron is IntentSourceTron, Inbox, Semver {
    constructor() {}
}
