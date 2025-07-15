/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";
import {IMessageBridgeProver} from "../interfaces/IMessageBridgeProver.sol";
import {Whitelist} from "../libs/Whitelist.sol";

/**
 * @title MessageBridgeProver
 * @notice Abstract contract for cross-chain message-based proving mechanisms
 * @dev Extends BaseProver with functionality for message bridge provers like Hyperlane and Metalayer
 */
abstract contract MessageBridgeProver is
    BaseProver,
    IMessageBridgeProver,
    Whitelist
{
    /**
     * @notice Default gas limit for cross-chain message dispatch
     * @dev Set at deployment and cannot be changed afterward
     */
    uint256 public immutable DEFAULT_GAS_LIMIT;

    /**
     * @notice Initializes the MessageBridgeProver contract
     * @param portal Address of the Portal contract
     * @param provers Array of trusted prover addresses (as bytes32 for cross-VM compatibility)
     * @param defaultGasLimit Default gas limit for cross-chain messages (200k if not specified)
     */
    constructor(
        address portal,
        bytes32[] memory provers,
        uint256 defaultGasLimit
    ) BaseProver(portal) Whitelist(provers) {
        if (portal == address(0)) revert PortalCannotBeZeroAddress();

        DEFAULT_GAS_LIMIT = defaultGasLimit > 0 ? defaultGasLimit : 200_000;
    }

    /**
     * @notice Validates that the message sender is authorized
     * @dev Template method for authorization check
     * @param messageSender Address attempting to call handle()
     * @param expectedSender Address that should be authorized
     */
    function _validateMessageSender(
        address messageSender,
        address expectedSender
    ) internal pure {
        if (expectedSender != messageSender) {
            revert UnauthorizedHandle(messageSender);
        }
    }

    /**
     * @notice Validates that the proving request is authorized
     * @param sender Address that sent the proving request
     */
    function _validateProvingRequest(address sender) internal view {
        if (sender != PORTAL) {
            revert UnauthorizedProve(sender);
        }
    }

    /**
     * @notice Send refund to the user if they've overpaid
     * @param recipient Address to send the refund to
     * @param amount Amount to refund
     */
    function _sendRefund(address recipient, uint256 amount) internal {
        if (amount > 0 && recipient != address(0)) {
            (bool success, ) = payable(recipient).call{
                value: amount,
                gas: 3000
            }("");
            if (!success) {
                revert NativeTransferFailed();
            }
        }
    }

    /**
     * @notice Handles cross-chain messages containing proof data
     * @dev Common implementation to validate and process cross-chain messages
     * @param sourceChainId Chain ID of the source chain
     * @param messageSender Address that dispatched the message on source chain (as bytes32 for cross-VM compatibility)
     * @param message Encoded array of intent hashes and claimants
     */
    function _handleCrossChainMessage(
        uint256 sourceChainId,
        bytes32 messageSender,
        bytes calldata message
    ) internal {
        // Verify dispatch originated from a whitelisted prover address
        if (!isWhitelisted(messageSender)) {
            revert UnauthorizedIncomingProof(messageSender);
        }

        // Decode message containing intent hashes and claimants
        (bytes32[] memory hashes, bytes32[] memory claimants) = abi.decode(
            message,
            (bytes32[], bytes32[])
        );

        // Process the intent proofs using shared implementation - array validation happens there
        // The source chain ID becomes the destination chain ID in the proof
        _processIntentProofs(hashes, claimants, sourceChainId);
    }
}
