// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseDepositFactory} from "./BaseDepositFactory.sol";
import {DepositAddress_GatewayDeposit} from "./DepositAddress_GatewayDeposit.sol";

/**
 * @title DepositFactory_GatewayDeposit
 * @notice Factory contract for deploying deterministic deposit addresses for Gateway deposits
 * @dev Creates LOCAL intents (same-chain fulfillment) on the Arc chain. Because source and
 *      destination are the same chain, TOKEN serves as both the source token (escrowed as the
 *      solver reward) and the destination token (transferred by the solver to fulfill the route).
 *      This factory is designed to be deployed on the Arc chain.
 *      Uses CREATE2 for deterministic address generation based on user's destination address.
 *
 * @dev Intent Call Flow:
 *      When a solver fulfills the intent, it executes:
 *      `Gateway.depositFor(address token, address depositor, uint256 amount)`
 *
 *      This deposits tokens into the Gateway contract on behalf of the user,
 *      crediting the depositor's account with the bridged tokens.
 *
 * @dev Prover Configuration:
 *      This factory should be configured with a LocalProver address, as intents
 *      are created and fulfilled on the same chain.
 */
contract DepositFactory_GatewayDeposit is BaseDepositFactory {

    // ============ Immutable Configuration ============

    /// @notice Token address (ERC20 on current chain — used for both route and reward)
    address public immutable TOKEN;

    /// @notice Portal contract address
    address public immutable PORTAL_ADDRESS;

    /// @notice Prover contract address
    address public immutable PROVER_ADDRESS;

    /// @notice Gateway contract address
    address public immutable GATEWAY_ADDRESS;

    /// @notice Intent deadline duration in seconds (e.g., 7 days)
    uint64 public immutable INTENT_DEADLINE_DURATION;

    // ============ Errors ============

    error InvalidGatewayAddress();

    // ============ Constructor ============

    /**
     * @notice Initialize the factory with route configuration
     * @param _token Token address (same token used for route and reward)
     * @param _portalAddress Portal contract address
     * @param _proverAddress LocalProver contract address
     * @param _gatewayAddress Gateway contract address
     * @param _intentDeadlineDuration Deadline duration for intents in seconds
     */
    constructor(
        address _token,
        address _portalAddress,
        address _proverAddress,
        address _gatewayAddress,
        uint64 _intentDeadlineDuration
    ) BaseDepositFactory(address(new DepositAddress_GatewayDeposit())) {
        // Validation
        if (_token == address(0)) revert InvalidSourceToken();
        if (_portalAddress == address(0)) revert InvalidPortalAddress();
        if (_proverAddress == address(0)) revert InvalidProverAddress();
        if (_gatewayAddress == address(0)) revert InvalidGatewayAddress();
        if (_intentDeadlineDuration == 0) revert InvalidDeadlineDuration();

        // Store configuration
        TOKEN = _token;
        PORTAL_ADDRESS = _portalAddress;
        PROVER_ADDRESS = _proverAddress;
        GATEWAY_ADDRESS = _gatewayAddress;
        INTENT_DEADLINE_DURATION = _intentDeadlineDuration;
    }

    // ============ External Functions ============

    /**
     * @notice Get complete factory configuration
     * @return token Token address
     * @return portalAddress Portal address
     * @return proverAddress LocalProver contract address
     * @return gatewayAddress Gateway contract address
     * @return intentDeadlineDuration Deadline duration in seconds
     */
    function getConfiguration()
        external
        view
        returns (
            address token,
            address portalAddress,
            address proverAddress,
            address gatewayAddress,
            uint64 intentDeadlineDuration
        )
    {
        return (
            TOKEN,
            PORTAL_ADDRESS,
            PROVER_ADDRESS,
            GATEWAY_ADDRESS,
            INTENT_DEADLINE_DURATION
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
        DepositAddress_GatewayDeposit(deployed).initialize(destinationBytes32, depositor);
    }
}
