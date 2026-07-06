// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Minimal Gateway surface used by {GatewayDepositRuntime}.
 * @dev Mirrors the `depositFor(address,address,uint256)` selector the one-shot deposit templates encode
 *      by hand.
 */
interface IGateway {
    function depositFor(address token, address recipient, uint256 amount) external;
}

/**
 * @title GatewayDepositRuntime
 * @notice BALANCE-READING v3 runtime for a STANDING Gateway-deposit flash pool (the destination leg of the
 *         CCTP deposit families): the payload commits CONFIG ONLY (`abi.encode(token, gateway, recipient)`),
 *         never an amount. Delegatecalled in the per-intent {Account}'s context, it deposits the Account's
 *         ENTIRE balance of `token` into the Gateway for `recipient` (the user).
 *
 * @dev STATELESS singleton reached exclusively via `delegatecall` from the Account (mirrors
 *      {MulticallRuntime} / the test {SweepRuntime}): the Account forwards `Route.payload` verbatim, so
 *      this contract's {fallback} decodes it and acts as the Account. It holds NO storage of its own.
 *
 *      Under the destination flash pool `rate == WAD`, so the slice equals the whole pool and the user
 *      receives the full CCTP mint. The amount is read LIVE (`balanceOf(this)`) because the per-slice
 *      amount varies with the pool and cannot be baked into the hash-committed payload. `forceApprove`
 *      handles the allowance-returns-to-0 case cleanly.
 */
contract GatewayDepositRuntime {
    using SafeERC20 for IERC20;

    /**
     * @notice Deposit the Account's whole balance of the configured token into the Gateway for the user.
     * @dev Reached via `delegatecall` from the Account with `Route.payload` as calldata:
     *      `abi.encode(address token, address gateway, address recipient)`.
     */
    fallback() external payable {
        (address token, address gateway, address recipient) = abi.decode(
            msg.data,
            (address, address, address)
        );

        uint256 x = IERC20(token).balanceOf(address(this));

        IERC20(token).forceApprove(gateway, x);
        IGateway(gateway).depositFor(token, recipient, x);
    }

    /// @notice Accept native (present for delegatecall-context symmetry).
    receive() external payable {}
}
