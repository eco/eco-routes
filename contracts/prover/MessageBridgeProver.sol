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
    ) internal view {
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
     * @notice Process intent proofs from a cross-chain message
     * @param _hashes Array of intent hashes
     * @param _claimants Array of claimant addresses
     */
    function _processIntentProofs(
        bytes32[] memory _hashes,
        address[] memory _claimants
    ) internal {
        // If arrays are empty, just return early
        if (_hashes.length == 0) return;

        // Require matching array lengths for security
        require(_hashes.length == _claimants.length, "Array length mismatch");

        for (uint256 i = 0; i < _hashes.length; i++) {
            (bytes32 intentHash, address claimant) = (
                _hashes[i],
                _claimants[i]
            );
            
            // Skip rather than revert for already proven intents
            if (provenIntents[intentHash] != address(0)) {
                emit IntentAlreadyProven(intentHash);
            } else {
                provenIntents[intentHash] = claimant;
                emit IntentProven(intentHash, claimant);
            }
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

    /**
     * @notice Initiates proving of intents via the message bridge
     * @dev Abstract method to be implemented by specific message bridge provers
     * @param _sender Address that initiated the proving request
     * @param _sourceChainId Chain ID of source chain
     * @param _intentHashes Array of intent hashes to prove
     * @param _claimants Array of claimant addresses
     * @param _data Additional data for message formatting
     */
    function destinationProve(
        address _sender,
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        bytes calldata _data
    ) external payable virtual override;

    /**
     * @notice Calculates the fee required for cross-chain message dispatch
     * @dev Abstract method to be implemented by specific message bridge provers
     * @param _sourceChainId Chain ID of the source chain
     * @param _intentHashes Array of intent hashes to prove
     * @param _claimants Array of claimant addresses
     * @param _data Additional data for message formatting
     * @return Fee amount in native tokens
     */
    function fetchFee(
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        bytes calldata _data
    ) public view virtual override returns (uint256);

    /**
     * @notice Returns the proof type used by this prover
     * @dev Abstract method to be implemented by specific message bridge provers
     * @return String indicating the proving mechanism
     */
    function getProofType() external pure virtual override returns (string memory);
}
