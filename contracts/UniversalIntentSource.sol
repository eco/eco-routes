/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UniversalSource} from "./source/UniversalSource.sol";

/**
 * @title UniversalIntentSource
 * @notice Compatibility wrapper for the refactored UniversalSource implementation
 * @dev This file maintains backward compatibility with existing code
 */
abstract contract UniversalIntentSource is UniversalSource {}