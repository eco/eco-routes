// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TestERC20} from "./TestERC20.sol";

/// @notice Test token that burns one unit only on transfers from the configured chainer.
contract FeeOnPushToken is TestERC20 {
    address internal immutable FEE_SENDER;

    constructor(address sender) TestERC20("Fee on push", "FEE") {
        FEE_SENDER = sender;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from == FEE_SENDER && to != address(0) && value > 0) {
            super._update(from, address(0), 1);
            super._update(from, to, value - 1);
        } else {
            super._update(from, to, value);
        }
    }
}
