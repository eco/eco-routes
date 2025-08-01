// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IProver} from "./interfaces/IProver.sol";
import {IExecutor} from "./interfaces/IExecutor.sol";

import {Call} from "./types/Intent.sol";

/**
 * @title Executor
 * @notice Contract for secure execution of intent calls
 * @dev Implements IExecutor with safety checks to prevent malicious calls
 */
contract Executor is IExecutor {
    /**
     * @notice Interface ID for IProver used to detect prover contracts
     */
    bytes4 private constant IPROVER_INTERFACE_ID = type(IProver).interfaceId;

    /**
     * @notice Address of the portal contract authorized to call execute
     */
    address private portal;

    /**
     * @notice Initializes the Executor contract
     * @dev Sets the deploying address (portal) as the only authorized caller
     */
    constructor() {
        portal = msg.sender;
    }

    /**
     * @notice Restricts function access to the portal contract only
     * @dev Reverts with Unauthorized error if caller is not the portal
     */
    modifier onlyPortal() {
        if (msg.sender != portal) {
            revert Unauthorized(msg.sender);
        }

        _;
    }

    /**
     * @notice Executes a intent call with comprehensive safety checks
     * @dev Performs multiple validation steps before execution:
     * 1. Prevents calls to EOAs that include calldata (potential phishing protection)
     * 2. Prevents calls to prover contracts (prevents circular execution)
     * 3. Executes the call and returns the result or reverts on failure
     * @param call The call data containing target address, value, and calldata
     * @return The return data from the successfully executed call
     */
    function execute(
        Call calldata call
    ) external payable override onlyPortal returns (bytes memory) {
        if (_isCallToEoa(call)) {
            revert CallToEOA(call.target);
        }

        if (_isProver(call.target)) {
            revert CallToProver(call.target);
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
     * @notice Checks if the target address is a prover contract
     * @dev Uses ERC165 interface detection to identify prover contracts
     * Prevents calls to provers to avoid circular execution and maintain system integrity
     * @param target The address to check
     * @return bool True if the target implements the IProver interface
     */
    function _isProver(address target) internal view returns (bool) {
        if (target.code.length == 0) {
            return false;
        }

        try IERC165(target).supportsInterface(IPROVER_INTERFACE_ID) returns (
            bool isProver
        ) {
            return isProver;
        } catch {
            return false;
        }
    }
}
