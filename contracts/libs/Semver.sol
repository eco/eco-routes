// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ISemver} from "../interfaces/ISemver.sol";

abstract contract Semver is ISemver {
    function version() external pure returns (string memory) {
        return "1.5.23-e80e631";
    }
}
