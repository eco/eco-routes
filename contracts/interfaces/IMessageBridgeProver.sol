// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProver} from "./IProver.sol";
import {Intent, Route, Call, TokenAmount} from "../types/Intent.sol";

/**
 * @title IMessageBridgeProver
 * @notice Interface for message-bridge based provers
 * @dev Defines common functionality and events for cross-chain message bridge provers
 */
interface IMessageBridgeProver is IProver {
    /**
     * @notice Insufficient fee provided for cross-chain message dispatch
     * @param _requiredFee Amount of fee required
     */
    error InsufficientFee(uint256 _requiredFee);

    /**
     * @notice Native token transfer failed
     */
    error NativeTransferFailed();

    /**
     * @notice Chain ID is too large for destination chain format
     * @param _chainId The chain ID that couldn't be converted
     */
    error ChainIdTooLarge(uint256 _chainId);

    /**
     * @notice Unauthorized call to handle() detected
     * @param _sender Address that attempted the call
     */
    error UnauthorizedHandle(address _sender);

    /**
     * @notice Unauthorized call to initiate proving
     * @param _sender Address that initiated
     */
    error UnauthorizedProve(address _sender);

    /**
     * @notice Unauthorized incoming proof from source chain
     * @param _sender Address that initiated the proof
     */
    error UnauthorizedIncomingProof(address _sender);

    /**
     * @notice Mailbox address cannot be zero
     */
    error MailboxCannotBeZeroAddress();

    /**
     * @notice Router address cannot be zero
     */
    error RouterCannotBeZeroAddress();

    /**
     * @notice Inbox address cannot be zero
     */
    error InboxCannotBeZeroAddress();

    /**
     * @notice Invalid chain ID for the origin
     */
    error InvalidOriginChainId();

    /**
     * @notice Sender address cannot be zero
     */
    error SenderCannotBeZeroAddress();

    /**
     * @notice Emitted when a batch of fulfilled intents is sent to be relayed to the source chain
     * @param _hashes Intent hashes sent in the batch
     * @param _sourceChainID ID of the source chain
     */
    event BatchSent(bytes32[] indexed _hashes, uint256 indexed _sourceChainID);

    /**
     * @notice Calculates the fee required for message dispatch
     * @param _sourceChainID Chain ID of source chain
     * @param _intentHashes Array of intent hashes to prove
     * @param _claimants Array of claimant addresses
     * @param _data Additional data for message formatting.
     *        Specific format varies by implementation:
     *        - HyperProver: (bytes32 sourceChainProver, bytes metadata, address hookAddr, [uint256 gasLimitOverride])
     *        - MetaProver: (bytes32 sourceChainProver, [uint256 gasLimitOverride])
     * @return Fee amount required for message dispatch
     */
    function fetchFee(
        Route[] calldata _routes,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        bytes calldata _data
    ) external view returns (uint256);
}
