/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Semver} from "./libs/Semver.sol";
import {IntentSource} from "./IntentSource.sol";
import {Inbox} from "./Inbox.sol";
import {AccountTron} from "./tron/AccountTron.sol";

/**
 * @title PortalTron
 * @notice Portal variant for Tron chains. Combines IntentSource and Inbox functionality.
 * @dev Uses AccountTron clones (via the 0x41 CREATE2 prefix) to support non-standard ERC20
 *      tokens such as Tron USDT.
 */
contract PortalTron is IntentSource, Inbox, Semver {
    constructor() IntentSource(address(new AccountTron()), bytes1(0x41)) {}

    /**
     * @notice Deterministic address of the intent's per-intent Account (composition-root wiring).
     * @dev Lets the destination-side {Inbox} address the same CREATE2 account the source-side
     *      {IntentSource} escrow uses, so unconsumed solver input lands with the intent.
     */
    function _predictAccount(
        bytes32 intentHash
    ) internal view override returns (address) {
        return _getAccount(intentHash);
    }
}
