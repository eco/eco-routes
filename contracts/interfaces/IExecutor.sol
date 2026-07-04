// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Call, TokenAmount} from "../types/Intent.sol";

/**
 * @title IExecutor
 * @notice Interface for secure batch execution of intent calls
 * @dev Provides controlled execution with built-in safety checks and authorization
 * - Restricts execution to authorized portal contracts only
 * - Prevents calls to EOAs with calldata
 * - Supports batch execution for multiple calls in a single transaction
 */
interface IExecutor {
    /**
     * @notice Thrown when caller is not the portal to execute calls
     * @param caller The unauthorized address that attempted the call
     */
    error NonPortalCaller(address caller);

    /**
     * @notice Attempted call to an EOA
     * @param target EOA address to which call was attempted
     */
    error CallToEOA(address target);

    /**
     * @notice Call to a contract failed
     * @param call The call that failed
     * @param reason The reason for the failure
     */
    error CallFailed(Call call, bytes reason);

    /**
     * @notice Moving unconsumed native input to its destination failed
     * @param to The intended destination of the moved native (the intent's Account)
     * @param amount The native amount that could not be delivered
     */
    error NativeSweepFailed(address to, uint256 amount);

    /**
     * @notice Executes multiple intent calls with safety checks
     * @dev Validates each target address and executes calls if safe
     * - Prevents calls to EOAs that include calldata
     * - Reverts if any target call fails
     * @param calls Array of call data containing target, value, and calldata
     * @return Array of return data from the executed calls
     */
    function execute(
        Call[] calldata calls
    ) external payable returns (bytes[] memory);

    /**
     * @notice Moves any unconsumed input held by the executor to `to`
     * @dev Called by the Portal after {execute} to move the solver-provided input the calls did not
     *      consume to the intent's Account (leftover stays with the intent). For each leg the full
     *      remaining balance of that token is transferred (native `address(0)` via a low-level call). A
     *      zero remaining balance is a no-op.
     * @param tokens The input legs to move (typically `route.minTokens`)
     * @param to The address that receives the unconsumed input (the intent's Account)
     */
    function sweepTo(TokenAmount[] calldata tokens, address to) external;
}
