/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Semver} from "./libs/Semver.sol";

import {IntentSource} from "./IntentSource.sol";
import {Inbox} from "./Inbox.sol";
import {Account} from "./account/Account.sol";

/**
 * @title Portal
 * @notice Portal contract combining IntentSource and Inbox functionality
 * @dev Main entry point for intent publishing, fulfillment, and proving
 */
contract Portal is IntentSource, Inbox, Semver {
    /**
     * @notice Initializes the Portal contract
     * @dev Creates a unified entry point combining source and destination chain functionality
     * @param nativeErc20 ERC20 token address aliased to this deployment's native asset, or
     *        `address(0)` if none. See {IntentSource-NATIVE_ERC20}.
     */
    constructor(
        address nativeErc20
    ) IntentSource(address(new Account()), bytes1(0xff), nativeErc20) {}

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
