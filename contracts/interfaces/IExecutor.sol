// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Call} from "../types/Intent.sol";

/**
 * @title IExecutor
 * @notice Interface for secure execution of intent calls
 * @dev Provides controlled execution with built-in safety checks to prevent
 * calls to provers and EOAs with calldata
 */
interface IExecutor {
    /**
     * @notice Thrown when caller is not authorized to execute calls
     * @param caller The unauthorized address that attempted the call
     */
    error Unauthorized(address caller);

    /**
     * @notice Attempted call to a destination-chain prover
     * @param target Prover address to which call was attempted
     */
    error CallToProver(address target);

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
     * @notice Executes a intent call with safety checks
     * @dev Validates the target address and executes the call if safe
     * - Prevents calls to EOAs that include calldata
     * - Prevents calls to prover contracts
     * - Reverts if the target call fails
     * @param call The call data containing target, value, and calldata
     * @return The return data from the executed call
     */
    function execute(
        Call calldata call
    ) external payable returns (bytes memory);
}
