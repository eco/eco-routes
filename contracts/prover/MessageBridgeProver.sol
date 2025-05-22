/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";
import {IMessageBridgeProver} from "../interfaces/IMessageBridgeProver.sol";
import {Whitelist} from "../tools/Whitelist.sol";
import {MinimalRoute, Route} from "../types/Intent.sol";

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
     * @param _provers Array of trusted prover addresses
     * @param _defaultGasLimit Default gas limit for cross-chain messages (200k if not specified)
     */
    constructor(
        address _inbox,
        address[] memory _provers,
        uint256 _defaultGasLimit
    ) BaseProver(_inbox) Whitelist(_provers) {
        if (_inbox == address(0)) revert InboxCannotBeZeroAddress();

        DEFAULT_GAS_LIMIT = _defaultGasLimit > 0 ? _defaultGasLimit : 200_000;
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
     * @notice Converts a chain ID to a domain ID
     * @dev Used for compatibility with different chain ID formats
     * @param _chainID Chain ID to convert
     * @dev placeholder that works, but will be replaced in future versions
     * @dev 1380012617 is the chain ID for Rarichain, but the domainID is 1000012617.
     * @dev all other chains that will be supported in the immediate future will have the same chain ID and domain ID
     * @return domain ID
     */
    function _convertChainIDToDomainID(
        uint256 _chainID
    ) internal pure returns (uint32) {
        // Convert chain ID to Hyperlane domain ID format
        // Validate the chain ID can fit in uint32 to prevent truncation issues
        if (_chainID > type(uint32).max) {
            revert ChainIdTooLarge(_chainID);
        }
        if (_chainID == uint256(1380012617)) {
            return uint32(1000012617);
        }
        return uint32(_chainID);
    }

    /**
     * @notice Converts a domain ID to a chian ID
     * @dev Used for compatibility with different chain ID formats
     * @param _domainID domain ID to convert
     * @dev placeholder that works, but will be replaced in future versions
     * @dev 1000012617 is the domain ID for Rarichain, but the chainID is 1380012617.
     * @dev all other chains that will be supported in the immediate future will have the same chain ID and domain ID
     * @return chain ID
     */
    function _convertDomainIDToChainID(
        uint32 _domainID
    ) internal pure returns (uint256) {
        if (_domainID == uint32(1000012617)) {
            return uint256(1380012617);
        }
        return uint256(_domainID);
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
     * @param _destinationDomain domain ID of the destination chain
     * @param _messageSender Address that dispatched the message on destination chain
     * @param _message Encoded array of intent hashes and claimants
     */
    function _handleCrossChainMessage(
        uint32 _destinationDomain,
        address _messageSender,
        bytes calldata _message
    ) internal {
        // Verify dispatch originated from a whitelisted prover address
        if (!isWhitelisted(_messageSender)) {
            revert UnauthorizedIncomingProof(_messageSender);
        }

        // Decode message containing intent hashes and claimants
        (
            address inbox,
            MinimalRoute[] memory minimalRoutes,
            bytes32[] memory rewardHashes,
            address[] memory claimants
        ) = abi.decode(_message, (address, MinimalRoute[], bytes32[], address[]));

        uint256 destinationChainID = _convertDomainIDToChainID(
            (_destinationDomain)
        );
        bytes32[] memory hashes = new bytes32[](minimalRoutes.length);
        for (uint256 i = 0; i < minimalRoutes.length; i++) {
            Route memory route = Route(
                minimalRoutes[i].salt,
                block.chainid,
                destinationChainID,
                inbox,
                minimalRoutes[i].tokens,
                minimalRoutes[i].calls
            );
            hashes[i] = keccak256(
                abi.encodePacked(keccak256(abi.encode(route)), rewardHashes[i])
            );
        }

        // Process the intent proofs using shared implementation - array validation happens there
        _processIntentProofs(hashes, claimants);
    }
}
