/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";
import {IMessageBridgeProver} from "../interfaces/IMessageBridgeProver.sol";
import {Whitelist} from "../libs/Whitelist.sol";
import {Intent} from "../types/Intent.sol";

/**
 * @title MessageBridgeProver
 * @notice Abstract contract for cross-chain message-based proving mechanisms
 * @notice the terms "source" and "destination" are used in reference to a given intent: created on source chain, fulfilled on destination chain
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
     * @param _inbox Address of the Inbox contract
     * @param _provers Array of trusted prover addresses (as bytes32 for cross-VM compatibility)
     * @param _defaultGasLimit Default gas limit for cross-chain messages (200k if not specified)
     */
    constructor(
        address _inbox,
        bytes32[] memory _provers,
        uint256 _defaultGasLimit
    ) BaseProver(_inbox) Whitelist(_provers) {
        if (_inbox == address(0)) revert InboxCannotBeZeroAddress();

        DEFAULT_GAS_LIMIT = _defaultGasLimit > 0 ? _defaultGasLimit : 200_000;
    }

    /**
     * @notice Challenges a recorded proof
     * @param _intent Intent to challenge
     * @dev Clears the proof if the destination chain ID in the intent does not match the one in the proof
     * @dev even if not challenged, an incorrect proof cannot be used to claim rewards.
     * @dev does nothing if chainID is correct.
     */
    function challengeIntentProof(Intent calldata _intent) public {
        bytes32 intentHash = keccak256(
            abi.encodePacked(
                keccak256(abi.encode(_intent.route)),
                keccak256(abi.encode(_intent.reward))
            )
        );
        uint96 trueDestinationChainID = uint96(_intent.route.destination);

        ProofData storage proofData = _provenIntents[intentHash];

        if (trueDestinationChainID != proofData.destinationChainID) {
            if (proofData.destinationChainID != 0) {
                proofData.claimant = address(0);
                emit BadProofCleared(intentHash);
            }

            proofData.destinationChainID = trueDestinationChainID;
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
            revert UnauthorizedProve(_sender);
        }
    }

    /**
     * @notice Send refund to the user if they've overpaid
     * @param _recipient Address to send the refund to
     * @param _amount Amount to refund
     */
    function _sendRefund(address _recipient, uint256 _amount) internal {
        if (_amount > 0 && _recipient != address(0)) {
            (bool success, ) = payable(_recipient).call{
                value: _amount,
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
     * @param _sourceChainId Chain ID of the source chain (not used for whitelist validation)
     * @param _messageSender Address that dispatched the message on source chain (as bytes32 for cross-VM compatibility)
     * @param _message Encoded array of intent hashes and claimants
     */
    function _handleCrossChainMessage(
        uint256 _sourceChainId,
        bytes32 _messageSender,
        bytes calldata _message
    ) internal {
        // Verify dispatch originated from a whitelisted prover address
        if (!isWhitelisted(_messageSender)) {
            revert UnauthorizedIncomingProof(_messageSender);
        }

        uint96 destinationChainID = uint96(_sourceChainId);
        // Decode message containing intent hashes and claimants
        // Claimants are encoded as bytes32 for cross-VM compatibility
        (bytes32[] memory hashes, bytes32[] memory claimantBytes) = abi.decode(
            _message,
            (bytes32[], bytes32[])
        );

        // Convert bytes32 claimants to addresses
        address[] memory claimants = new address[](claimantBytes.length);
        for (uint256 i = 0; i < claimantBytes.length; i++) {
            claimants[i] = address(uint160(uint256(claimantBytes[i])));
        }

        // Process the intent proofs using shared implementation - array validation happens there
        _processIntentProofs(destinationChainID, hashes, claimants);
    }
}
