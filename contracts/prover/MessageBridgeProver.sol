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
     * @notice Minimum gas limit for cross-chain message dispatch
     * @dev Set at deployment and cannot be changed afterward. Gas limits below this value will be increased to this minimum.
     */
    uint256 public immutable MIN_GAS_LIMIT;

    /**
     * @notice Chain ID is too large to fit in uint32
     * @param chainId The chain ID that is too large
     */
    error ChainIdTooLarge(uint256 chainId);

    /**
     * @notice Initializes the MessageBridgeProver contract
     * @param portal Address of the Portal contract
     * @param provers Array of trusted prover addresses (as bytes32 for cross-VM compatibility)
     * @param minGasLimit Minimum gas limit for cross-chain messages (200k if not specified or zero)
     */
    constructor(
        address portal,
        bytes32[] memory provers,
        uint256 minGasLimit
    ) BaseProver(portal) Whitelist(provers) {
        if (portal == address(0)) revert PortalCannotBeZeroAddress();

        MIN_GAS_LIMIT = minGasLimit > 0 ? minGasLimit : 200_000;
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
     * @param message Encoded array of (intentHash, claimant) pairs
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

        // Process the intent proofs directly from bytes data
        // The source chain ID becomes the destination chain ID in the proof
        _processIntentProofs(message, sourceChainId);
    }

    /**
     * @notice Common prove function implementation for message bridge provers
     * @dev Handles fee calculation, validation, and message dispatch
     * @param sender Address that initiated the proving request
     * @param sourceChainId Chain ID of the source chain
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     * @param data Additional data for message formatting
     */
    function prove(
        address sender,
        uint256 sourceChainId,
        bytes calldata encodedProofs,
        bytes calldata data
    ) external payable virtual override {
        // Validate the request is from Portal
        _validateProvingRequest(msg.sender);

        // Calculate fee using implementation-specific logic
        uint256 fee = fetchFee(sourceChainId, encodedProofs, data);

        // Check if enough fee was provided
        if (msg.value < fee) {
            revert InsufficientFee(fee);
        }

        // Calculate refund amount if overpaid
        uint256 refundAmount = 0;
        if (msg.value > fee) {
            refundAmount = msg.value - fee;
        }

        // Dispatch message using implementation-specific logic
        _dispatchMessage(sourceChainId, encodedProofs, data, fee);

        // Send refund if needed
        _sendRefund(sender, refundAmount);
    }

    /**
     * @notice Validates that arrays have matching lengths
     * @dev Common validation used by both HyperProver and MetaProver
     * @param hashes Array of intent hashes
     * @param claimants Array of claimant addresses
     */
    function _validateArrayLengths(
        bytes32[] calldata hashes,
        bytes32[] calldata claimants
    ) internal pure {
        if (hashes.length != claimants.length) {
            revert ArrayLengthMismatch();
        }
    }

    /**
     * @notice Validates and converts chain ID to uint32
     * @dev Common validation for chain ID conversion
     * @param chainId Chain ID to validate
     * @return uint32 representation of the chain ID
     */
    function _validateChainId(uint256 chainId) internal pure returns (uint32) {
        if (chainId > type(uint32).max) {
            revert ChainIdTooLarge(chainId);
        }
        return uint32(chainId);
    }

    /**
     * @notice Abstract function to dispatch message via specific bridge
     * @dev Must be implemented by concrete provers (HyperProver, MetaProver)
     * @param sourceChainId Chain ID of the source chain
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     * @param data Additional data for message formatting
     * @param fee Fee amount for message dispatch
     */
    function _dispatchMessage(
        uint256 sourceChainId,
        bytes calldata encodedProofs,
        bytes calldata data,
        uint256 fee
    ) internal virtual;

    /**
     * @notice Fetches fee required for message dispatch
     * @dev Must be implemented by concrete provers to calculate bridge-specific fees
     * @param sourceChainId Chain ID of the source chain
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     * @param data Additional data for message formatting
     * @return Fee amount required for message dispatch
     */
    function fetchFee(
        uint256 sourceChainId,
        bytes calldata encodedProofs,
        bytes calldata data
    ) public view virtual returns (uint256);
}
