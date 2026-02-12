// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BaseDepositAddress
 * @notice Base contract for deposit addresses with common initialization and validation
 * @dev Provides initialization, balance checks, and template for intent creation
 *      Derived contracts must implement variant-specific intent execution
 */
abstract contract BaseDepositAddress is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Storage ============

    /// @notice User's destination address on target chain (used for CREATE2 salt and token recipient)
    address public destinationAddress;

    /// @notice Depositor address on source chain (where refunds are sent if intent fails)
    address public depositor;

    /// @notice Initialization flag
    bool private initialized;

    // ============ Errors ============

    error AlreadyInitialized();
    error NotInitialized();
    error OnlyFactory();
    error InvalidDestinationAddress();
    error InvalidDepositor();
    error ZeroAmount();
    error InsufficientBalance(uint256 requested, uint256 available);

    // ============ External Functions ============

    /**
     * @notice Initialize the deposit address (called once by factory after deployment)
     * @param _destinationAddress User's destination address (used for salt and token recipient)
     * @param _depositor Address to receive refunds if intent fails
     */
    function initialize(
        address _destinationAddress,
        address _depositor
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (msg.sender != _factory()) revert OnlyFactory();
        if (_destinationAddress == address(0)) revert InvalidDestinationAddress();
        if (_depositor == address(0)) revert InvalidDepositor();

        destinationAddress = _destinationAddress;
        depositor = _depositor;
        initialized = true;
    }

    /**
     * @notice Create a cross-chain intent for deposited tokens
     * @dev Template method: validates common requirements, delegates to variant-specific execution
     * @param amount Amount of tokens to bridge
     * @return intentHash Hash of the created intent
     */
    function createIntent(
        uint256 amount
    ) external nonReentrant returns (bytes32 intentHash) {
        if (!initialized) revert NotInitialized();
        if (amount == 0) revert ZeroAmount();

        // Get source token from derived contract
        address sourceToken = _getSourceToken();

        // Check balance
        uint256 balance = IERC20(sourceToken).balanceOf(address(this));
        if (balance < amount) {
            revert InsufficientBalance(amount, balance);
        }

        // Execute variant-specific intent creation
        intentHash = _executeIntent(amount);

        return intentHash;
    }

    // ============ Internal Functions ============

    /**
     * @notice Get the factory address that deployed this contract
     * @dev Must be implemented by derived contracts to return their factory reference
     * @return Address of the factory contract
     */
    function _factory() internal view virtual returns (address);

    /**
     * @notice Get the source token address for this deposit
     * @dev Must be implemented by derived contracts to return their source token
     * @return Address of the source token
     */
    function _getSourceToken() internal view virtual returns (address);

    /**
     * @notice Execute variant-specific intent creation logic
     * @dev Must be implemented by derived contracts to construct and publish their intent
     * @param amount Amount of tokens to bridge
     * @return intentHash Hash of the created intent
     */
    function _executeIntent(uint256 amount) internal virtual returns (bytes32 intentHash);
}
