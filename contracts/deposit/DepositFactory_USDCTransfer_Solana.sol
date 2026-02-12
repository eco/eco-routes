// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "../vault/Clones.sol";
import {DepositAddress_USDCTransfer_Solana} from "./DepositAddress_USDCTransfer_Solana.sol";

/**
 * @title DepositFactory_USDCTransfer_Solana
 * @notice Factory contract for deploying deterministic deposit addresses for USDC transfers to Solana
 * @dev Each factory is configured for a specific cross-chain route (e.g., Ethereum USDC → Solana USDC)
 *      Uses CREATE2 for deterministic address generation based on user's destination address
 */
contract DepositFactory_USDCTransfer_Solana {
    using Clones for address;

    // ============ Constants ============

    /// @notice Solana chain ID
    uint64 public constant DESTINATION_CHAIN = 1399811149;

    // ============ Immutable Configuration ============

    /// @notice Source token address (ERC20 on source chain)
    address public immutable SOURCE_TOKEN;

    /// @notice Destination token address on destination chain (as bytes32 for cross-VM compatibility)
    bytes32 public immutable DESTINATION_TOKEN;

    /// @notice Portal contract address on source chain
    address public immutable PORTAL_ADDRESS;

    /// @notice Prover contract address
    address public immutable PROVER_ADDRESS;

    /// @notice Portal program address on destination chain (as bytes32 for Solana)
    bytes32 public immutable DESTINATION_PORTAL;

    /// @notice Portal's PDA vault authority on Solana (owns Executor ATA)
    bytes32 public immutable PORTAL_PDA;

    /// @notice Intent deadline duration in seconds (e.g., 7 days)
    uint64 public immutable INTENT_DEADLINE_DURATION;

    /// @notice Executor's Associated Token Account on Solana (for source funds)
    bytes32 public immutable EXECUTOR_ATA;

    /// @notice DepositAddress implementation contract
    address public immutable DEPOSIT_IMPLEMENTATION;

    // ============ Events ============

    /**
     * @notice Emitted when a new deposit contract is deployed
     * @param destinationAddress Recipient's Associated Token Account (ATA) on Solana
     * @param depositAddress Deployed DepositAddress contract address
     */
    event DepositContractDeployed(
        bytes32 indexed destinationAddress,
        address indexed depositAddress
    );

    // ============ Errors ============

    error InvalidSourceToken();
    error InvalidPortalAddress();
    error InvalidProverAddress();
    error InvalidDeadlineDuration();
    error InvalidDestinationPortal();
    error InvalidDestinationAddress();
    error InvalidDestinationToken();
    error InvalidPortalPDA();
    error InvalidExecutorATA();

    // ============ Constructor ============

    /**
     * @notice Initialize the factory with route configuration
     * @param _sourceToken ERC20 token address on source chain
     * @param _destinationToken Token address on destination chain (as bytes32)
     * @param _portalAddress Portal contract address on source chain
     * @param _proverAddress Prover contract address
     * @param _destinationPortal Portal program ID on destination chain (as bytes32)
     * @param _portalPDA Portal's PDA vault authority on Solana
     * @param _intentDeadlineDuration Deadline duration for intents in seconds
     * @param _executorATA Executor's Associated Token Account on Solana
     */
    constructor(
        address _sourceToken,
        bytes32 _destinationToken,
        address _portalAddress,
        address _proverAddress,
        bytes32 _destinationPortal,
        bytes32 _portalPDA,
        uint64 _intentDeadlineDuration,
        bytes32 _executorATA
    ) {
        // Validation
        if (_sourceToken == address(0)) revert InvalidSourceToken();
        if (_destinationToken == bytes32(0)) revert InvalidDestinationToken();
        if (_portalAddress == address(0)) revert InvalidPortalAddress();
        if (_proverAddress == address(0)) revert InvalidProverAddress();
        if (_destinationPortal == bytes32(0)) revert InvalidDestinationPortal();
        if (_portalPDA == bytes32(0)) revert InvalidPortalPDA();
        if (_intentDeadlineDuration == 0) revert InvalidDeadlineDuration();
        if (_executorATA == bytes32(0)) revert InvalidExecutorATA();

        // Store configuration
        SOURCE_TOKEN = _sourceToken;
        DESTINATION_TOKEN = _destinationToken;
        PORTAL_ADDRESS = _portalAddress;
        PROVER_ADDRESS = _proverAddress;
        DESTINATION_PORTAL = _destinationPortal;
        PORTAL_PDA = _portalPDA;
        INTENT_DEADLINE_DURATION = _intentDeadlineDuration;
        EXECUTOR_ATA = _executorATA;

        // Deploy implementation contract
        DEPOSIT_IMPLEMENTATION = address(new DepositAddress_USDCTransfer_Solana());
    }

    // ============ External Functions ============

    /**
     * @notice Get deterministic deposit address for a user
     * @dev Can be called before deployment to predict the address
     * @param destinationAddress Recipient's Associated Token Account (ATA) on Solana where tokens will be sent
     * @param depositor Address to receive refunds if intent fails
     * @return Predicted deposit address on source chain
     */
    function getDepositAddress(
        bytes32 destinationAddress,
        address depositor
    ) public view returns (address) {
        bytes32 salt = _getSalt(destinationAddress, depositor);
        return DEPOSIT_IMPLEMENTATION.predict(salt, bytes1(0xff));
    }

    /**
     * @notice Deploy deposit contract for a user
     * @dev For Solana destinations, destinationAddress should be the recipient's Associated Token Account (ATA)
     *      computed off-chain from: deriveAddress([ownerPubkey, TOKEN_PROGRAM_ID, mintPubkey], ATA_PROGRAM_ID)
     * @param destinationAddress Recipient's Associated Token Account (ATA) on Solana where tokens will be sent
     * @param depositor Address to receive refunds if intent fails
     * @return deployed Address of the deployed DepositAddress contract
     */
    function deploy(
        bytes32 destinationAddress,
        address depositor
    ) external returns (address deployed) {
        if (destinationAddress == bytes32(0)) revert InvalidDestinationAddress();

        bytes32 salt = _getSalt(destinationAddress, depositor);
        deployed = DEPOSIT_IMPLEMENTATION.clone(salt);

        // Initialize the deposit address with destination and depositor
        DepositAddress_USDCTransfer_Solana(deployed).initialize(destinationAddress, depositor);

        emit DepositContractDeployed(destinationAddress, deployed);
    }

    /**
     * @notice Check if deposit contract is deployed for a user
     * @param destinationAddress Recipient's Associated Token Account (ATA) on Solana
     * @param depositor Address to receive refunds if intent fails
     * @return True if contract exists at predicted address
     */
    function isDeployed(
        bytes32 destinationAddress,
        address depositor
    ) external view returns (bool) {
        address predicted = getDepositAddress(destinationAddress, depositor);
        return predicted.code.length > 0;
    }

    /**
     * @notice Get complete factory configuration
     * @return destinationChain Target chain ID
     * @return sourceToken Source token address
     * @return destinationToken Destination token address (bytes32)
     * @return portalAddress Portal address on source chain
     * @return proverAddress Prover contract address
     * @return destinationPortal Portal program ID on destination chain (bytes32)
     * @return portalPDA Portal's PDA vault authority on Solana
     * @return intentDeadlineDuration Deadline duration in seconds
     * @return executorATA Executor's Associated Token Account on Solana
     */
    function getConfiguration()
        external
        view
        returns (
            uint64 destinationChain,
            address sourceToken,
            bytes32 destinationToken,
            address portalAddress,
            address proverAddress,
            bytes32 destinationPortal,
            bytes32 portalPDA,
            uint64 intentDeadlineDuration,
            bytes32 executorATA
        )
    {
        return (
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            PORTAL_ADDRESS,
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            PORTAL_PDA,
            INTENT_DEADLINE_DURATION,
            EXECUTOR_ATA
        );
    }

    // ============ Internal Functions ============

    /**
     * @notice Generate CREATE2 salt from destination address and depositor
     * @param destinationAddress Recipient's Associated Token Account (ATA) on Solana
     * @param depositor Address to receive refunds if intent fails
     * @return salt The CREATE2 salt
     */
    function _getSalt(
        bytes32 destinationAddress,
        address depositor
    ) internal pure returns (bytes32) {
        // Hash both destination address and depositor for unique salt
        return keccak256(abi.encodePacked(destinationAddress, depositor));
    }
}
