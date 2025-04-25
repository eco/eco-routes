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
     * @notice Mapping of addresses to their prover whitelist status
     * @dev Used to authorize cross-chain message senders
     */
    mapping(address => bool) public proverWhitelist;

    /**
     * @notice Initializes the MessageBridgeProver contract
     * @param _inbox Address of the Inbox contract
     * @param _provers Array of trusted prover addresses to whitelist
     */
    constructor(address _inbox, address[] memory _provers) BaseProver(_inbox) {
        proverWhitelist[address(this)] = true;
        for (uint256 i = 0; i < _provers.length; i++) {
            proverWhitelist[_provers[i]] = true;
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
            revert UnauthorizedDestinationProve(_sender);
        }
    }


    /**
     * @notice Process payment and refund excess fees
     * @param _fee Required fee amount
     * @param _sender Address to refund excess fee to
     */
    function _processPayment(uint256 _fee, address _sender) internal {
        if (msg.value < _fee) {
            revert InsufficientFee(_fee);
        }
        if (msg.value > _fee) {
            (bool success, ) = payable(_sender).call{value: msg.value - _fee}(
                ""
            );
            if (!success) {
                revert NativeTransferFailed();
            }
        }
    }
}
