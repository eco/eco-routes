// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "../vault/Clones.sol";

/**
 * @title BaseDepositFactory
 * @notice Base contract for deposit factories with common deployment logic
 * @dev Provides CREATE2 deployment, deterministic addressing, and deployment tracking
 *      Derived contracts must implement variant-specific configuration and initialization
 */
abstract contract BaseDepositFactory {
    using Clones for address;

    // ============ Immutables ============

    /// @notice DepositAddress implementation contract for cloning
    address public immutable DEPOSIT_IMPLEMENTATION;

    // ============ Events ============

    /**
     * @notice Emitted when a new deposit contract is deployed
     * @param destinationAddress User's destination address on target chain
     * @param depositor Address to receive refunds if intent fails
     * @param depositContract Address of deployed deposit contract
     */
    event DepositContractDeployed(
        address indexed destinationAddress,
        address indexed depositor,
        address indexed depositContract
    );

    // ============ Errors ============

    error InvalidSourceToken();
    error InvalidPortalAddress();
    error InvalidProverAddress();
    error InvalidDeadlineDuration();
    error InvalidDestinationPortal();
    error InvalidDestinationAddress();
    error InvalidDepositor();

    // ============ Constructor ============

    /**
     * @notice Initializes base factory by deploying implementation contract
     * @param implementation Address of the deployed DepositAddress implementation
     */
    constructor(address implementation) {
        DEPOSIT_IMPLEMENTATION = implementation;
    }

    // ============ External Functions ============

    /**
     * @notice Deploy a new deposit address using CREATE2 for deterministic addressing
     * @param destinationAddress User's destination address on target chain
     * @param depositor Address to receive refunds if intent fails
     * @return deployed Address of the deployed deposit contract
     */
    function deploy(
        address destinationAddress,
        address depositor
    ) external returns (address deployed) {
        if (destinationAddress == address(0)) revert InvalidDestinationAddress();
        if (depositor == address(0)) revert InvalidDepositor();

        // Deploy using CREATE2 with deterministic salt
        bytes32 salt = _getSalt(destinationAddress, depositor);
        deployed = DEPOSIT_IMPLEMENTATION.clone(salt);

        // Initialize the deployed contract
        _initializeDeployedContract(deployed, destinationAddress, depositor);

        emit DepositContractDeployed(destinationAddress, depositor, deployed);
        return deployed;
    }

    /**
     * @notice Predict the deterministic address for a deposit contract
     * @dev Uses the standard EVM CREATE2 prefix (0xff). These contracts are intended for
     *      deployment on fully EVM-compatible chains only. Chains with a non-standard CREATE2
     *      prefix (e.g. TRON, which uses 0x41) will produce incorrect address predictions.
     * @param destinationAddress User's destination address on target chain
     * @param depositor Address to receive refunds if intent fails
     * @return predicted Deterministic address of the deposit contract
     */
    function getDepositAddress(
        address destinationAddress,
        address depositor
    ) public view returns (address predicted) {
        if (destinationAddress == address(0)) revert InvalidDestinationAddress();
        if (depositor == address(0)) revert InvalidDepositor();

        bytes32 salt = _getSalt(destinationAddress, depositor);
        return DEPOSIT_IMPLEMENTATION.predict(salt, bytes1(0xff));
    }

    /**
     * @notice Check if a deposit contract has been deployed
     * @param destinationAddress User's destination address on target chain
     * @param depositor Address to receive refunds if intent fails
     * @return True if contract exists at predicted address
     */
    function isDeployed(
        address destinationAddress,
        address depositor
    ) external view returns (bool) {
        address predicted = getDepositAddress(destinationAddress, depositor);
        return predicted.code.length > 0;
    }

    // ============ Internal Functions ============

    /**
     * @notice Generate CREATE2 salt from destination address and depositor
     * @param destinationAddress User's destination address on target chain
     * @param depositor Address to receive refunds if intent fails
     * @return Salt for CREATE2 deployment
     */
    function _getSalt(
        address destinationAddress,
        address depositor
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(destinationAddress, depositor));
    }

    /**
     * @notice Initialize the deployed deposit contract
     * @dev Must be implemented by derived contracts to call appropriate initialize function
     * @param deployed Address of the newly deployed contract
     * @param destinationAddress User's destination address on target chain
     * @param depositor Address to receive refunds if intent fails
     */
    function _initializeDeployedContract(
        address deployed,
        address destinationAddress,
        address depositor
    ) internal virtual;
}
