// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "../vault/Clones.sol";
import {EVMDepositAddress} from "./EVMDepositAddress.sol";

/**
 * @title EVMDepositFactory
 * @notice Factory contract for deploying deterministic deposit addresses for EVM destinations
 * @dev Each factory is configured for a specific cross-chain route (e.g., Ethereum USDC → Optimism USDC)
 *      Uses CREATE2 for deterministic address generation based on user's destination address
 *      This version uses standard Intent structs instead of Borsh-encoded bytes
 */
contract EVMDepositFactory {
    using Clones for address;

    // ============ Immutable Configuration ============

    /// @notice Destination chain ID (e.g., 10 for Optimism, 137 for Polygon)
    uint64 public immutable DESTINATION_CHAIN;

    /// @notice Source token address (ERC20 on source chain)
    address public immutable SOURCE_TOKEN;

    /// @notice Target token address on destination chain (ERC20 address)
    address public immutable TARGET_TOKEN;

    /// @notice Portal contract address on source chain
    address public immutable PORTAL_ADDRESS;

    /// @notice Prover contract address
    address public immutable PROVER_ADDRESS;

    /// @notice Portal contract address on destination chain
    address public immutable DESTINATION_PORTAL;

    /// @notice Intent deadline duration in seconds (e.g., 7 days)
    uint64 public immutable INTENT_DEADLINE_DURATION;

    /// @notice EVMDepositAddress implementation contract
    address public immutable DEPOSIT_IMPLEMENTATION;

    // ============ Events ============

    /**
     * @notice Emitted when a new deposit contract is deployed
     * @param destinationAddress User's destination address on target chain
     * @param depositAddress Deployed EVMDepositAddress contract address
     */
    event DepositContractDeployed(
        address indexed destinationAddress,
        address indexed depositAddress
    );

    // ============ Errors ============

    error InvalidSourceToken();
    error InvalidPortalAddress();
    error InvalidProverAddress();
    error InvalidTargetToken();
    error InvalidDestinationPortal();
    error InvalidDeadlineDuration();
    error ContractAlreadyDeployed(address depositAddress);

    // ============ Constructor ============

    /**
     * @notice Initialize the factory with route configuration
     * @param _destinationChain Target chain ID
     * @param _sourceToken ERC20 token address on source chain
     * @param _targetToken ERC20 token address on destination chain
     * @param _portalAddress Portal contract address on source chain
     * @param _proverAddress Prover contract address
     * @param _destinationPortal Portal contract address on destination chain
     * @param _intentDeadlineDuration Deadline duration for intents in seconds
     */
    constructor(
        uint64 _destinationChain,
        address _sourceToken,
        address _targetToken,
        address _portalAddress,
        address _proverAddress,
        address _destinationPortal,
        uint64 _intentDeadlineDuration
    ) {
        // Validation
        if (_sourceToken == address(0)) revert InvalidSourceToken();
        if (_portalAddress == address(0)) revert InvalidPortalAddress();
        if (_proverAddress == address(0)) revert InvalidProverAddress();
        if (_targetToken == address(0)) revert InvalidTargetToken();
        if (_destinationPortal == address(0)) revert InvalidDestinationPortal();
        if (_intentDeadlineDuration == 0) revert InvalidDeadlineDuration();

        // Store configuration
        DESTINATION_CHAIN = _destinationChain;
        SOURCE_TOKEN = _sourceToken;
        TARGET_TOKEN = _targetToken;
        PORTAL_ADDRESS = _portalAddress;
        PROVER_ADDRESS = _proverAddress;
        DESTINATION_PORTAL = _destinationPortal;
        INTENT_DEADLINE_DURATION = _intentDeadlineDuration;

        // Deploy implementation contract
        DEPOSIT_IMPLEMENTATION = address(new EVMDepositAddress());
    }

    // ============ External Functions ============

    /**
     * @notice Get deterministic deposit address for a user
     * @dev Can be called before deployment to predict the address
     * @param destinationAddress User's address on destination chain
     * @return Predicted deposit address on source chain
     */
    function getDepositAddress(
        address destinationAddress
    ) public view returns (address) {
        bytes32 salt = _getSalt(destinationAddress);
        return DEPOSIT_IMPLEMENTATION.predict(salt, bytes1(0xff));
    }

    /**
     * @notice Deploy deposit contract for a user
     * @param destinationAddress User's address on destination chain (used as CREATE2 salt)
     * @param recipient Address that will receive tokens on destination chain
     * @param depositor Address to receive refunds if intent fails
     * @return deployed Address of the deployed EVMDepositAddress contract
     */
    function deploy(
        address destinationAddress,
        address recipient,
        address depositor
    ) external returns (address deployed) {
        address predicted = getDepositAddress(destinationAddress);

        // Check if already deployed
        if (predicted.code.length > 0) {
            revert ContractAlreadyDeployed(predicted);
        }

        bytes32 salt = _getSalt(destinationAddress);
        deployed = DEPOSIT_IMPLEMENTATION.clone(salt);

        // Initialize the deposit address with destination, recipient, and depositor
        EVMDepositAddress(deployed).initialize(
            destinationAddress,
            recipient,
            depositor
        );

        emit DepositContractDeployed(destinationAddress, deployed);
    }

    /**
     * @notice Check if deposit contract is deployed for a user
     * @param destinationAddress User's address on destination chain
     * @return True if contract exists at predicted address
     */
    function isDeployed(
        address destinationAddress
    ) external view returns (bool) {
        address predicted = getDepositAddress(destinationAddress);
        return predicted.code.length > 0;
    }

    /**
     * @notice Get complete factory configuration
     * @return destinationChain Target chain ID
     * @return sourceToken Source token address
     * @return targetToken Target token address
     * @return portalAddress Portal address on source chain
     * @return proverAddress Prover contract address
     * @return destinationPortal Portal address on destination chain
     * @return intentDeadlineDuration Deadline duration in seconds
     */
    function getConfiguration()
        external
        view
        returns (
            uint64 destinationChain,
            address sourceToken,
            address targetToken,
            address portalAddress,
            address proverAddress,
            address destinationPortal,
            uint64 intentDeadlineDuration
        )
    {
        return (
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            TARGET_TOKEN,
            PORTAL_ADDRESS,
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            INTENT_DEADLINE_DURATION
        );
    }

    // ============ Internal Functions ============

    /**
     * @notice Generate CREATE2 salt from destination address
     * @param destinationAddress User's destination address
     * @return salt The CREATE2 salt (address converted to bytes32)
     */
    function _getSalt(
        address destinationAddress
    ) internal pure returns (bytes32) {
        // Convert address to bytes32 for CREATE2 salt
        return bytes32(uint256(uint160(destinationAddress)));
    }
}
