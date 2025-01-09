// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library Semver {
    function version() internal pure returns (string memory) {
        return "0.1.0";
    }
}

/**
 * @title Semver Interface
 * @dev An interface for a contract that has a version
 */
interface ISemver {
    function version() external pure returns (string memory);
}
