/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Semver} from "./libs/Semver.sol";

import {UniversalSource} from "./UniversalSource.sol";
import {Inbox} from "./Inbox.sol";

/**
 * @title Portal
 * @notice Portal contract combining UniversalSource and Inbox functionality
 * @dev Main entry point for intent publishing, fulfillment, and proving
 */
contract Portal is UniversalSource, Inbox, Semver {
    /**
     * @notice Initializes the Portal contract
     * @dev Creates a unified entry point combining source and destination chain functionality
     */
    constructor() {}
}
