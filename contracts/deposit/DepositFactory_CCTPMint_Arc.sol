// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseDepositFactory} from "./BaseDepositFactory.sol";
import {DepositAddress_CCTPMint_Arc} from "./DepositAddress_CCTPMint_Arc.sol";

/**
 * @title DepositFactory_CCTPMint_Arc
 * @notice Factory contract for deploying deterministic deposit addresses for CCTP transfers to Arc
 * @dev Deploys deposit addresses which allow users to deposit funds into CCTP to be transferred to Arc chain.
 *      Creates LOCAL intents (same-chain fulfillment).
 *      Uses CREATE2 for deterministic address generation based on user's destination address.
 *
 * @dev Prover Configuration:
 *      This factory should be configured with a LocalProver address, as intents
 *      are created and fulfilled on the same chain.
 */
contract DepositFactory_CCTPMint_Arc is BaseDepositFactory {
    // ============ Immutable Configuration ============

    /// @notice Source token address (ERC20 on current chain)
    address public immutable SOURCE_TOKEN;

    /// @notice Destination token address on destination chain
    address public immutable DESTINATION_TOKEN;

    /// @notice Portal contract address
    address public immutable PORTAL_ADDRESS;

    /// @notice Prover contract address
    address public immutable PROVER_ADDRESS;

    /// @notice Intent deadline duration in seconds (e.g., 7 days)
    uint64 public immutable INTENT_DEADLINE_DURATION;

    /// @notice CCTP destination domain ID for the target chain
    uint32 public immutable DESTINATION_DOMAIN;

    /// @notice CCTP TokenMessenger contract address on source chain
    address public immutable CCTP_TOKEN_MESSENGER;

    // ============ Errors ============

    error InvalidTargetToken();
    error InvalidCCTPTokenMessenger();

    // ============ Constructor ============

    /**
     * @notice Initialize the factory with route configuration
     * @param _sourceToken Source token address (burn token for CCTP)
     * @param _destinationToken Destination token address
     * @param _portalAddress Portal contract address
     * @param _proverAddress LocalProver contract address
     * @param _intentDeadlineDuration Deadline duration for intents in seconds
     * @param _destinationDomain CCTP destination domain ID
     * @param _cctpTokenMessenger CCTP TokenMessenger contract address
     */
    constructor(
        address _sourceToken,
        address _destinationToken,
        address _portalAddress,
        address _proverAddress,
        uint64 _intentDeadlineDuration,
        uint32 _destinationDomain,
        address _cctpTokenMessenger
    ) BaseDepositFactory(address(new DepositAddress_CCTPMint_Arc())) {
        // Validation
        if (_sourceToken == address(0)) revert InvalidSourceToken();
        if (_portalAddress == address(0)) revert InvalidPortalAddress();
        if (_proverAddress == address(0)) revert InvalidProverAddress();
        if (_destinationToken == address(0)) revert InvalidTargetToken();
        if (_intentDeadlineDuration == 0) revert InvalidDeadlineDuration();
        if (_cctpTokenMessenger == address(0)) revert InvalidCCTPTokenMessenger();

        // Store configuration
        SOURCE_TOKEN = _sourceToken;
        DESTINATION_TOKEN = _destinationToken;
        PORTAL_ADDRESS = _portalAddress;
        PROVER_ADDRESS = _proverAddress;
        INTENT_DEADLINE_DURATION = _intentDeadlineDuration;
        DESTINATION_DOMAIN = _destinationDomain;
        CCTP_TOKEN_MESSENGER = _cctpTokenMessenger;
    }

    // ============ External Functions ============

    /**
     * @notice Get complete factory configuration
     * @return sourceToken Source token address
     * @return destinationToken Destination token address
     * @return portalAddress Portal address
     * @return proverAddress LocalProver contract address
     * @return intentDeadlineDuration Deadline duration in seconds
     * @return destinationDomain CCTP destination domain ID
     * @return cctpTokenMessenger CCTP TokenMessenger contract address
     */
    function getConfiguration()
        external
        view
        returns (
            address sourceToken,
            address destinationToken,
            address portalAddress,
            address proverAddress,
            uint64 intentDeadlineDuration,
            uint32 destinationDomain,
            address cctpTokenMessenger
        )
    {
        return (
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            PORTAL_ADDRESS,
            PROVER_ADDRESS,
            INTENT_DEADLINE_DURATION,
            DESTINATION_DOMAIN,
            CCTP_TOKEN_MESSENGER
        );
    }

    // ============ Internal Functions ============

    /**
     * @notice Initialize the deployed deposit contract
     * @dev Implementation of abstract function from BaseDepositFactory
     * @param deployed Address of the newly deployed contract
     * @param destinationAddress User's destination address on target chain
     * @param depositor Address to receive refunds if intent fails
     */
    function _initializeDeployedContract(
        address deployed,
        address destinationAddress,
        address depositor
    ) internal override {
        // Convert EVM address to bytes32 for universal destination address format
        bytes32 destinationBytes32 = bytes32(uint256(uint160(destinationAddress)));
        DepositAddress_CCTPMint_Arc(deployed).initialize(destinationBytes32, depositor);
    }
}
