/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";
import {IMessageBridgeProver} from "../interfaces/IMessageBridgeProver.sol";

/**
 * @title MessageBridgeProver
 * @notice Abstract contract for cross-chain message-based proving mechanisms
 * @dev Extends BaseProver with functionality for message bridge provers like Hyperlane and Metalayer
 */
abstract contract MessageBridgeProver is BaseProver, IMessageBridgeProver {
    /**
     * @notice Mapping of chain IDs to addresses to their prover whitelist status
     * @dev Used to authorize cross-chain message senders from specific chains
     */
    mapping(uint256 => mapping(address => bool)) public proverWhitelist;

    /**
     * @notice Default gas limit for cross-chain message dispatch
     * @dev Set at deployment and cannot be changed afterward
     */
    uint256 public immutable DEFAULT_GAS_LIMIT;

    /**
     * @notice Initializes the MessageBridgeProver contract
     * @param _inbox Address of the Inbox contract
     * @param _provers Array of trusted provers to whitelist
     * @param _defaultGasLimit Default gas limit for cross-chain messages (200k if not specified)
     */
    constructor(
        address _inbox,
        TrustedProver[] memory _provers,
        uint256 _defaultGasLimit
    ) BaseProver(_inbox) {
        DEFAULT_GAS_LIMIT = _defaultGasLimit > 0 ? _defaultGasLimit : 200_000;
        // Add this contract to the whitelist on the current chain
        proverWhitelist[block.chainid][address(this)] = true;

        // Add all provided trusted provers to their respective chains
        for (uint256 i = 0; i < _provers.length; i++) {
            proverWhitelist[_provers[i].chainId][_provers[i].prover] = true;
        }
    }

    /**
     * @notice Validates that the message sender is authorized
     * @dev Template method for authorization check
     * @param _messageSender Address attempting to call handle()
     * @param _expectedSender Address that should be authorized
     */
    function _validateMessageSender(
        address _messageSender,
        address _expectedSender
    ) internal pure {
        if (_expectedSender != _messageSender) {
            revert UnauthorizedHandle(_messageSender);
        }
    }

    /**
     * @notice Validates that the proving request is authorized
     * @param _sender Address that sent the proving request
     */
    function _validateProvingRequest(address _sender) internal view {
        if (_sender != INBOX) {
            revert UnauthorizedSendProof(_sender, "not-inbox");
        }
    }

    /**
     * @notice Send refund to the user if they've overpaid
     * @param _recipient Address to send the refund to
     * @param _amount Amount to refund
     */
    function _sendRefund(address _recipient, uint256 _amount) internal {
        if (_amount > 0) {
            (bool success, ) = payable(_recipient).call{value: _amount}("");
            if (!success) {
                revert NativeTransferFailed();
            }
        }
    }

    /**
     * @notice Handles cross-chain messages containing proof data
     * @dev Common implementation to validate and process cross-chain messages
     * @param _sourceChainId Chain ID of the source chain
     * @param _messageSender Address that dispatched the message on source chain
     * @param _message Encoded array of intent hashes and claimants
     */
    function _handleCrossChainMessage(
        uint256 _sourceChainId,
        address _messageSender,
        bytes memory _message
    ) internal {
        // Verify dispatch originated from a valid prover on the specific source chain
        if (!proverWhitelist[_sourceChainId][_messageSender]) {
            revert UnauthorizedIncomingProof(_messageSender);
        }

        // Decode message containing intent hashes and claimants
        (bytes32[] memory hashes, address[] memory claimants) = abi.decode(
            _message,
            (bytes32[], address[])
        );

        // Validate that array lengths match
        if (hashes.length != claimants.length) {
            revert ArrayLengthMismatch();
        }

        // Process the intent proofs using shared implementation
        _processIntentProofs(hashes, claimants);
    }
}
