/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Semver} from "./libs/Semver.sol";

import {IntentSource} from "./IntentSource.sol";
import {Inbox} from "./Inbox.sol";

/**
 * @title Portal
 * @notice Portal contract combining IntentSource and Inbox functionality
 * @dev Main entry point for intent publishing, fulfillment, and proving
 */
contract Portal is IntentSource, Inbox, Semver {

    /**
     * @notice Chain ID is too large to fit in uint64
     * @param chainId The chain ID that is too large
     */
    error ChainIdTooLarge(uint256 chainId);


    /**
     * @notice Initializes the Portal contract
     * @dev Creates a unified entry point combining source and destination chain functionality
     */
    constructor() {}
    
    function _validateChainID(uint256 chainId) internal view override(IntentSource, Inbox) returns (uint64) {
        if (chainId > type(uint64).max) {
            revert ChainIdTooLarge(chainId);
        }
        return uint64(chainId);
    }
}
