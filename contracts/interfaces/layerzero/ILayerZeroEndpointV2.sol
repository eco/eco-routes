// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

/**
 * @title ILayerZeroEndpointV2
 * @notice Interface for LayerZero V2 endpoint contract
 * @dev Defines the core messaging functions for cross-chain communication
 */
interface ILayerZeroEndpointV2 {
    /**
     * @notice Struct containing messaging parameters for LayerZero
     * @param dstEid Destination endpoint ID
     * @param nativeFee Native fee amount to send
     * @param lzTokenFee LayerZero token fee amount
     */
    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    /**
     * @notice Struct containing messaging parameters
     * @param dstEid Destination endpoint ID
     * @param receiver Receiver address on destination chain (as bytes32)
     * @param message Message payload to send
     * @param options Execution options for the message
     * @param payInLzToken Whether to pay fees in LZ token
     */
    struct MessagingParams {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        bool payInLzToken;
    }

    /**
     * @notice Struct containing messaging receipt information
     * @param guid Globally unique identifier for the message
     * @param nonce Message nonce
     * @param fee Messaging fee paid
     */
    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    /**
     * @notice Send a message to another chain
     * @param params Messaging parameters
     * @param refundAddress Address to refund excess fees
     * @return receipt Message receipt containing guid and fee info
     */
    function send(
        MessagingParams calldata params,
        address refundAddress
    ) external payable returns (MessagingReceipt memory receipt);

    /**
     * @notice Quote the fee for sending a message
     * @param params Messaging parameters
     * @param sender Address of the message sender
     * @return fee The messaging fee quote
     */
    function quote(
        MessagingParams calldata params,
        address sender
    ) external view returns (MessagingFee memory fee);

    /**
     * @notice Set configuration for a specific endpoint and config type
     * @param _oapp Address of the OAPP contract 
     * @param _lib Address of the message library
     * @param _params Configuration parameters
     */
    function setConfig(
        address _oapp,
        address _lib,
        SetConfigParam[] calldata _params
    ) external;

    /**
     * @notice Set delegate for message handling
     * @param delegate Address of the delegate
     */
    function setDelegate(address delegate) external;

    function setSendLibrary(
        address _oapp,
        uint32 _eid,
        address _newLib,
    ) external;

    function setReceiveLibrary(
        address _oapp,
        uint32 _eid,
        address _newLib,
        uint256_ gracePeriod
    ) external;
}
