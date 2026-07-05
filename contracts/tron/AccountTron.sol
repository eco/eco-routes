// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Account} from "../account/Account.sol";
import {TronTransfer} from "../libs/TronTransfer.sol";

/**
 * @title AccountTron
 * @notice Account variant for Tron chains that handles non-standard ERC20 tokens.
 * @dev Overrides _transferToken to use a raw low-level call instead of SafeERC20.safeTransfer.
 *      Tron USDT (compiled with solc 0.4.x) returns false from transfer() even on success;
 *      SafeERC20 would revert on that. The balance-check in TronTransfer catches genuine failures.
 */
contract AccountTron is Account {
    /**
     * @notice Creates the Tron Account implementation bound to its portal.
     * @param _portal The authorized caller (the {PortalProxy}).
     */
    constructor(address _portal) Account(_portal) {}

    /**
     * @inheritdoc Account
     */
    function _transferToken(
        IERC20 token,
        address to,
        uint256 amount
    ) internal override {
        TronTransfer.transfer(token, to, amount);
    }
}
