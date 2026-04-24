// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TronTransfer
 * @notice Transfer helper for non-standard ERC20 tokens on Tron.
 * @dev Tron USDT (compiled with solc 0.4.x) returns false from transfer() even on
 *      success. SafeERC20 would revert on that. This library uses a raw low-level
 *      call instead and confirms tokens actually moved via a before/after balance check.
 */
library TronTransfer {
    /// @notice Thrown when an ERC20 token transfer fails (call reverted or tokens did not move)
    error TokenTransferFailed(address token);

    /**
     * @notice Transfers ERC20 tokens using a raw call, tolerating tokens that
     *         return false from transfer() despite moving funds.
     * @param token ERC20 token to transfer
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function transfer(IERC20 token, address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 before = token.balanceOf(address(this));
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = address(token).call(
            abi.encodeCall(IERC20.transfer, (to, amount))
        );
        if (!ok || token.balanceOf(address(this)) >= before) {
            revert TokenTransferFailed(address(token));
        }
    }
}
