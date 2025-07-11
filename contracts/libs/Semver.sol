// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ISemver} from "../interfaces/ISemver.sol";

/**
 * @title Semver
 * @notice Implements semantic versioning for contracts
 * @dev Abstract contract that provides a standard way to access version information
 *
 * NOTE: Contract versions are manually managed here and are NOT automatically updated
 * by the semantic-release process. This ensures explicit control over on-chain version
 * reporting and prevents automated changes from affecting deployed contracts.
 *
 * When updating the version:
 * 1. Update the return value in the version() function below
 * 2. Keep this version in sync with major package releases
 * 3. Document the change in release notes
 */
abstract contract Semver is ISemver {
    /**
     * @notice Returns the semantic version of the contract
     * @dev Implementation of ISemver interface
     * @return Current version string in semantic format
     */
    function version() external pure returns (string memory) {
        return "2.6";
    }
}
