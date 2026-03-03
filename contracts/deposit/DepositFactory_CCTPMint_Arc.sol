// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseDepositFactory} from "./BaseDepositFactory.sol";
import {DepositAddress_CCTPMint_Arc} from "./DepositAddress_CCTPMint_Arc.sol";

/**
 * @title DepositFactory_CCTPMint_Arc
 * @notice Factory contract for deploying deterministic deposit addresses for CCTP+Gateway transfers to Arc
 * @dev Deploys deposit addresses which create TWO intents:
 *      1. A CCTP burn intent on the source chain that bridges USDC to Arc via depositForBurn
 *      2. A Gateway deposit intent on Arc that deposits USDC into the Gateway for the user
 *      Uses CREATE2 for deterministic address generation based on user's destination address.
 *
 * @dev Prover Configuration:
 *      This factory should be configured with a LocalProver address for the source chain,
 *      and an ARC_PROVER_ADDRESS for the Arc chain.
 */
contract DepositFactory_CCTPMint_Arc is BaseDepositFactory {

    // ============ Immutable Configuration ============

    /// @notice Source token address (USDC ERC20 on source chain)
    address public immutable SOURCE_TOKEN;

    /// @notice Portal contract address on source chain
    address public immutable PORTAL_ADDRESS;

    /// @notice LocalProver contract address on source chain
    address public immutable PROVER_ADDRESS;

    /// @notice Intent deadline duration in seconds for both intents
    uint64 public immutable INTENT_DEADLINE_DURATION;

    /// @notice CCTP destination domain ID for Arc
    uint32 public immutable DESTINATION_DOMAIN;

    /// @notice CCTP TokenMessengerV2 contract address on source chain
    address public immutable CCTP_TOKEN_MESSENGER;

    /// @notice Arc chain ID
    uint64 public immutable ARC_CHAIN_ID;

    /// @notice LocalProver contract address on Arc
    address public immutable ARC_PROVER_ADDRESS;

    /// @notice USDC ERC20 address on Arc (6 decimals)
    address public immutable ARC_USDC;

    /// @notice Gateway contract address on Arc
    address public immutable GATEWAY_ADDRESS;

    // ============ Errors ============

    error InvalidCCTPTokenMessenger();
    error InvalidArcChainId();
    error InvalidArcProverAddress();
    error InvalidArcUsdc();
    error InvalidGatewayAddress();

    // ============ Constructor ============

    /**
     * @notice Initialize the factory with route configuration
     * @param _sourceToken Source token address (USDC on source chain)
     * @param _portalAddress Portal contract address on source chain
     * @param _proverAddress LocalProver contract address on source chain
     * @param _intentDeadlineDuration Deadline duration for intents in seconds
     * @param _destinationDomain CCTP destination domain ID for Arc
     * @param _cctpTokenMessenger CCTP TokenMessengerV2 contract address on source chain
     * @param _arcChainId Arc chain ID
     * @param _arcProverAddress LocalProver contract address on Arc
     * @param _arcUsdc USDC ERC20 address on Arc
     * @param _gatewayAddress Gateway contract address on Arc
     */
    constructor(
        address _sourceToken,
        address _portalAddress,
        address _proverAddress,
        uint64 _intentDeadlineDuration,
        uint32 _destinationDomain,
        address _cctpTokenMessenger,
        uint64 _arcChainId,
        address _arcProverAddress,
        address _arcUsdc,
        address _gatewayAddress
    ) BaseDepositFactory(address(new DepositAddress_CCTPMint_Arc())) {
        // Validation
        // Note: _destinationDomain is intentionally not validated because CCTP domain 0
        // is valid (it represents Ethereum mainnet), so all uint32 values are acceptable.
        if (_sourceToken == address(0)) revert InvalidSourceToken();
        if (_portalAddress == address(0)) revert InvalidPortalAddress();
        if (_proverAddress == address(0)) revert InvalidProverAddress();
        if (_intentDeadlineDuration == 0) revert InvalidDeadlineDuration();
        if (_cctpTokenMessenger == address(0)) revert InvalidCCTPTokenMessenger();
        if (_arcChainId == 0) revert InvalidArcChainId();
        if (_arcProverAddress == address(0)) revert InvalidArcProverAddress();
        if (_arcUsdc == address(0)) revert InvalidArcUsdc();
        if (_gatewayAddress == address(0)) revert InvalidGatewayAddress();

        // Store configuration
        SOURCE_TOKEN = _sourceToken;
        PORTAL_ADDRESS = _portalAddress;
        PROVER_ADDRESS = _proverAddress;
        INTENT_DEADLINE_DURATION = _intentDeadlineDuration;
        DESTINATION_DOMAIN = _destinationDomain;
        CCTP_TOKEN_MESSENGER = _cctpTokenMessenger;
        ARC_CHAIN_ID = _arcChainId;
        ARC_PROVER_ADDRESS = _arcProverAddress;
        ARC_USDC = _arcUsdc;
        GATEWAY_ADDRESS = _gatewayAddress;
    }

    // ============ External Functions ============

    /**
     * @notice Get complete factory configuration
     * @return sourceToken Source token address (USDC on source chain)
     * @return portalAddress Portal address on source chain
     * @return proverAddress LocalProver address on source chain
     * @return intentDeadlineDuration Deadline duration in seconds
     * @return destinationDomain CCTP destination domain ID for Arc
     * @return cctpTokenMessenger CCTP TokenMessengerV2 address on source chain
     * @return arcChainId Arc chain ID
     * @return arcProverAddress LocalProver address on Arc
     * @return arcUsdc USDC ERC20 address on Arc
     * @return gatewayAddress Gateway address on Arc
     */
    function getConfiguration()
        external
        view
        returns (
            address sourceToken,
            address portalAddress,
            address proverAddress,
            uint64 intentDeadlineDuration,
            uint32 destinationDomain,
            address cctpTokenMessenger,
            uint64 arcChainId,
            address arcProverAddress,
            address arcUsdc,
            address gatewayAddress
        )
    {
        return (
            SOURCE_TOKEN,
            PORTAL_ADDRESS,
            PROVER_ADDRESS,
            INTENT_DEADLINE_DURATION,
            DESTINATION_DOMAIN,
            CCTP_TOKEN_MESSENGER,
            ARC_CHAIN_ID,
            ARC_PROVER_ADDRESS,
            ARC_USDC,
            GATEWAY_ADDRESS
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
