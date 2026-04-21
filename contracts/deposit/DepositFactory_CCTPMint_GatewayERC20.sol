// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseDepositFactory} from "./BaseDepositFactory.sol";
import {DepositAddress_CCTPMint_GatewayERC20} from "./DepositAddress_CCTPMint_GatewayERC20.sol";

/**
 * @title DepositFactory_CCTPMint_GatewayERC20
 * @notice Factory contract for deploying deterministic deposit addresses for CCTP+Gateway transfers to ERC20 destinations
 * @dev Deploys deposit addresses which create TWO intents:
 *      1. A CCTP burn intent on the source chain that bridges USDC to the destination via depositForBurn
 *      2. A Gateway deposit intent on the destination that deposits USDC into the Gateway for the user
 *      Uses CREATE2 for deterministic address generation based on user's destination address.
 *      Unlike the Arc variant, the destination chain treats USDC as a standard ERC20 (not native token).
 *
 * @dev Prover Configuration:
 *      This factory should be configured with a LocalProver address for the source chain,
 *      and a DESTINATION_PROVER_ADDRESS for the destination chain.
 */
contract DepositFactory_CCTPMint_GatewayERC20 is BaseDepositFactory {
    // ============ Immutable Configuration ============

    /// @notice Source token address (USDC ERC20 on source chain)
    address public immutable SOURCE_TOKEN;

    /// @notice Portal contract address on source chain
    address public immutable PORTAL_ADDRESS;

    /// @notice LocalProver contract address on source chain
    address public immutable PROVER_ADDRESS;

    /// @notice Intent deadline duration in seconds for both intents
    uint64 public immutable INTENT_DEADLINE_DURATION;

    /// @notice CCTP destination domain ID for the destination chain
    uint32 public immutable DESTINATION_DOMAIN;

    /// @notice CCTP TokenMessengerV2 contract address on source chain
    address public immutable CCTP_TOKEN_MESSENGER;

    /// @notice Destination chain ID
    uint64 public immutable DESTINATION_CHAIN_ID;

    /// @notice LocalProver contract address on destination chain
    address public immutable DESTINATION_PROVER_ADDRESS;

    /// @notice USDC ERC20 address on destination chain
    address public immutable DESTINATION_USDC;

    /// @notice Gateway contract address on destination chain
    address public immutable GATEWAY_ADDRESS;

    /// @notice Maximum fee in basis points for CCTP fast-deposit (denominator: 100_000)
    uint256 public immutable MAX_FEE_BPS;

    /// @notice Denominator for fee basis point calculations
    uint256 public constant FEE_DENOMINATOR = 100_000;

    // ============ Errors ============

    error InvalidCCTPTokenMessenger();
    error InvalidDestinationChainId();
    error InvalidDestinationProverAddress();
    error InvalidDestinationUsdc();
    error InvalidGatewayAddress();

    // ============ Constructor ============

    /**
     * @notice Initialize the factory with route configuration
     * @param _sourceToken Source token address (USDC on source chain)
     * @param _portalAddress Portal contract address on source chain
     * @param _proverAddress LocalProver contract address on source chain
     * @param _intentDeadlineDuration Deadline duration for intents in seconds
     * @param _destinationDomain CCTP destination domain ID for the destination chain
     * @param _cctpTokenMessenger CCTP TokenMessengerV2 contract address on source chain
     * @param _destinationChainId Destination chain ID
     * @param _destinationProverAddress LocalProver contract address on destination chain
     * @param _destinationUsdc USDC ERC20 address on destination chain
     * @param _gatewayAddress Gateway contract address on destination chain
     * @param _maxFeeBps Maximum fee in basis points for CCTP fast-deposit (denominator: 100_000, e.g. 13 = 1.3 bps)
     */
    constructor(
        address _sourceToken,
        address _portalAddress,
        address _proverAddress,
        uint64 _intentDeadlineDuration,
        uint32 _destinationDomain,
        address _cctpTokenMessenger,
        uint64 _destinationChainId,
        address _destinationProverAddress,
        address _destinationUsdc,
        address _gatewayAddress,
        uint256 _maxFeeBps
    ) BaseDepositFactory(address(new DepositAddress_CCTPMint_GatewayERC20())) {
        // Validation
        // Note: _destinationDomain is intentionally not validated because CCTP domain 0
        // is valid (it represents Ethereum mainnet), so all uint32 values are acceptable.
        if (_sourceToken == address(0)) revert InvalidSourceToken();
        if (_portalAddress == address(0)) revert InvalidPortalAddress();
        if (_proverAddress == address(0)) revert InvalidProverAddress();
        if (_intentDeadlineDuration == 0) revert InvalidDeadlineDuration();
        if (_cctpTokenMessenger == address(0)) revert InvalidCCTPTokenMessenger();
        if (_destinationChainId == 0) revert InvalidDestinationChainId();
        if (_destinationProverAddress == address(0)) revert InvalidDestinationProverAddress();
        if (_destinationUsdc == address(0)) revert InvalidDestinationUsdc();
        if (_gatewayAddress == address(0)) revert InvalidGatewayAddress();

        // Store configuration
        SOURCE_TOKEN = _sourceToken;
        PORTAL_ADDRESS = _portalAddress;
        PROVER_ADDRESS = _proverAddress;
        INTENT_DEADLINE_DURATION = _intentDeadlineDuration;
        DESTINATION_DOMAIN = _destinationDomain;
        CCTP_TOKEN_MESSENGER = _cctpTokenMessenger;
        DESTINATION_CHAIN_ID = _destinationChainId;
        DESTINATION_PROVER_ADDRESS = _destinationProverAddress;
        DESTINATION_USDC = _destinationUsdc;
        GATEWAY_ADDRESS = _gatewayAddress;
        MAX_FEE_BPS = _maxFeeBps;
    }

    // ============ External Functions ============

    /**
     * @notice Get complete factory configuration
     * @return sourceToken Source token address (USDC on source chain)
     * @return portalAddress Portal address on source chain
     * @return proverAddress LocalProver address on source chain
     * @return intentDeadlineDuration Deadline duration in seconds
     * @return destinationDomain CCTP destination domain ID
     * @return cctpTokenMessenger CCTP TokenMessengerV2 address on source chain
     * @return destinationChainId Destination chain ID
     * @return destinationProverAddress LocalProver address on destination chain
     * @return destinationUsdc USDC ERC20 address on destination chain
     * @return gatewayAddress Gateway address on destination chain
     * @return maxFeeBps Maximum fee in basis points for CCTP fast-deposit
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
            uint64 destinationChainId,
            address destinationProverAddress,
            address destinationUsdc,
            address gatewayAddress,
            uint256 maxFeeBps
        )
    {
        return (
            SOURCE_TOKEN,
            PORTAL_ADDRESS,
            PROVER_ADDRESS,
            INTENT_DEADLINE_DURATION,
            DESTINATION_DOMAIN,
            CCTP_TOKEN_MESSENGER,
            DESTINATION_CHAIN_ID,
            DESTINATION_PROVER_ADDRESS,
            DESTINATION_USDC,
            GATEWAY_ADDRESS,
            MAX_FEE_BPS
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
        DepositAddress_CCTPMint_GatewayERC20(deployed).initialize(destinationBytes32, depositor);
    }
}
