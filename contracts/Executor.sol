// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IExecutor} from "./interfaces/IExecutor.sol";

import {Call, TokenAmount} from "./types/Intent.sol";

/**
 * @title Executor
 * @notice Contract for secure batch execution of intent calls
 * @dev Implements IExecutor with comprehensive safety checks and authorization controls
 * - Only the portal contract can execute calls (onlyPortal modifier)
 * - Prevents malicious calls through EOA validation
 * - Supports batch execution for multiple calls in a single transaction
 */
contract Executor is IExecutor {
    using SafeERC20 for IERC20;

    /**
     * @notice Address of the portal contract authorized to call execute
     */
    address private immutable portal;

    /**
     * @notice Initializes the Executor contract
     * @dev Sets the deploying address (portal) as the only authorized caller
     */
    constructor() {
        portal = msg.sender;
    }

    /**
     * @notice Restricts function access to the portal contract only
     * @dev Reverts with NonPortalCaller error if caller is not the portal
     */
    modifier onlyPortal() {
        if (msg.sender != portal) {
            revert NonPortalCaller(msg.sender);
        }

        _;
    }

    /**
     * @notice Executes multiple intent calls with comprehensive safety checks
     * @dev Performs validation and execution for each call in the batch:
     * 1. Prevents calls to EOAs that include calldata (potential phishing protection)
     * 2. Executes each call and returns results or reverts on any failure
     * @param calls Array of call data containing target addresses, values, and calldata
     * @return Array of return data from the successfully executed calls
     */
    function execute(
        Call[] calldata calls
    ) external payable override onlyPortal returns (bytes[] memory) {
        uint256 callsLength = calls.length;
        bytes[] memory results = new bytes[](callsLength);

        for (uint256 i = 0; i < callsLength; i++) {
            results[i] = execute(calls[i]);
        }

        return results;
    }

    function execute(Call calldata call) internal returns (bytes memory) {
        if (_isCallToEoa(call)) {
            revert CallToEOA(call.target);
        }

        (bool success, bytes memory result) = call.target.call{
            value: call.value
        }(call.data);

        if (!success) {
            revert CallFailed(call, result);
        }

        return result;
    }

    /**
     * @notice Moves any unconsumed input held by the executor to `to`
     * @dev Only the Portal may call this (it runs immediately after {execute}). For each leg the full
     *      remaining balance of that token is forwarded to `to` — native (`address(0)`) via a low-level
     *      call, ERC20 via a safe transfer. A zero remaining balance is skipped so a leg the calls fully
     *      consumed costs nothing and never reverts on a zero-value transfer. The Portal passes the
     *      intent's Vault as `to`, keeping leftover with the intent for the creator to retrieve later.
     * @param tokens The input legs to move (typically `route.minTokens`)
     * @param to The address that receives the unconsumed input (the intent's Vault)
     */
    function sweepTo(
        TokenAmount[] calldata tokens,
        address to
    ) external override onlyPortal {
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; ++i) {
            address token = tokens[i].token;
            if (token == address(0)) {
                uint256 balance = address(this).balance;
                if (balance > 0) {
                    (bool ok, ) = to.call{value: balance}("");
                    if (!ok) {
                        revert NativeSweepFailed(to, balance);
                    }
                }
            } else {
                uint256 balance = IERC20(token).balanceOf(address(this));
                if (balance > 0) {
                    IERC20(token).safeTransfer(to, balance);
                }
            }
        }
    }

    /**
     * @notice Checks if a call is targeting an EOA with calldata
     * @dev Returns true if target has no code but calldata is provided
     * This prevents potential phishing attacks where calldata might be misinterpreted
     * @param call The call to validate
     * @return bool True if this is a potentially unsafe call to an EOA
     */
    function _isCallToEoa(Call calldata call) internal view returns (bool) {
        return call.target.code.length == 0 && call.data.length > 0;
    }

    /**
     * @notice Allows the contract to receive ETH
     * @dev Required for handling ETH transfer for intent execution
     */
    receive() external payable {}
}
