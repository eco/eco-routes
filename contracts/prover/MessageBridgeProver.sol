/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";
import {IMessageBridgeProver} from "../interfaces/IMessageBridgeProver.sol";
import {Whitelist} from "../tools/Whitelist.sol";
import {Intent} from "../types/Intent.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

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
    using SafeCast for uint256;

    uint256 public constant RARICHAIN_CHAIN_ID = 1380012617;
    uint256 public constant RARICHAIN_DOMAIN_ID = 1000012617;
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
     * @notice Converts a chain ID to a domain ID
     * @dev Used for compatibility with different chain ID formats
     * @param _chainID Chain ID to convert
     * @dev placeholder that works, but will be replaced in future versions
     * @dev 1380012617 is the chain ID for Rarichain, but the domainID is 1000012617.
     * @dev all other chains that will be supported in the immediate future will have the same chain ID and domain ID
     * @return domain ID
     */
    function _convertChainID(uint256 _chainID) internal pure returns (uint32) {
        if (_chainID == RARICHAIN_CHAIN_ID) {
            return uint32(RARICHAIN_DOMAIN_ID);
        }
        return _chainID.toUint32();
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
    function _convertDomainID(uint32 _domainID) internal pure returns (uint96) {
        if (_domainID == uint32(RARICHAIN_DOMAIN_ID)) {
            return uint96(RARICHAIN_CHAIN_ID);
        }
        return uint96(_domainID);
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
     * @param _destinationDomainID Domain ID of the destination chain
     * @param _messageSender Address that dispatched the message on destination chain
     * @param _message Encoded array of intent hashes and claimants
     */
    function _handleCrossChainMessage(
        uint32 _destinationDomainID,
        address _messageSender,
        bytes calldata _message
    ) internal {
        // Verify dispatch originated from a whitelisted prover address
        if (!isWhitelisted(_messageSender)) {
            revert UnauthorizedIncomingProof(_messageSender);
        }

        uint96 destinationChainID = _convertDomainID(_destinationDomainID);

        // Decode message containing intent hashes and claimants
        (bytes32[] memory hashes, address[] memory claimants) = abi.decode(
            _message,
            (bytes32[], address[])
        );

        // Process the intent proofs using shared implementation - array validation happens there
        _processIntentProofs(destinationChainID, hashes, claimants);
    }
}
