// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMetalayerRouter} from "@metalayer/contracts/src/interfaces/IMetalayerRouter.sol";
import {ReadOperation} from "@metalayer/contracts/src/interfaces/IMetalayerRecipient.sol";
import {FinalityState} from "@metalayer/contracts/src/lib/MetalayerMessage.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";

/**
 * @title TestMetaRouter
 * @notice A mock implementation of the Metalayer Router for testing purposes
 * @dev Simplifies testing of MetaProver without requiring a real Metalayer instance
 */
contract TestMetaRouter {
    using TypeCasts for bytes32;
    using TypeCasts for address;

    // Immutable domain ID for this chain
    uint32 public immutable LOCAL_DOMAIN;

    // Fee for metadata used in tests
    uint256 public constant FEE = 0.001 ether;

    // Mapping to track messages sent and enable verification in tests
    mapping(bytes32 => bool) public sentMessages;

    // Variables to store latest dispatch info for tests
    bool public dispatched;
    uint32 public destinationDomain;
    bytes32 public recipientAddress;
    bytes public messageBody;

    // Event emitted when a message is dispatched
    event MessageDispatched(
        uint32 destinationDomain,
        bytes32 recipient,
        bytes message
    );

    constructor(address /* _ignored */) {
        LOCAL_DOMAIN = 31337; // Hardhat local chain ID
    }

    /**
     * @notice Mock implementation of the dispatch function
     * @dev Records message details for test verification
     * @param _destinationDomain Target chain domain ID
     * @param _recipient Address that will receive the message on the destination
     * @param _message Message body to deliver
     * @return messageId A unique identifier for the dispatched message
     */
    function dispatch(
        uint32 _destinationDomain,
        bytes32 _recipient,
        ReadOperation[] calldata /* _operations */,
        bytes calldata _message,
        FinalityState /* _finality */,
        uint256 /* _gasLimit */
    ) external payable returns (bytes32 messageId) {
        // Store the message details for test verification
        dispatched = true;
        destinationDomain = _destinationDomain;
        recipientAddress = _recipient;
        messageBody = _message;

        // Generate a fake message ID for testing
        messageId = keccak256(
            abi.encode(
                _destinationDomain,
                _recipient,
                _message,
                block.timestamp
            )
        );

        // Record that this message was sent
        sentMessages[messageId] = true;

        // Emit event for test verification
        emit MessageDispatched(_destinationDomain, _recipient, _message);

        return messageId;
    }

    /**
     * @notice Mock implementation of the fee quotation function
     * @dev Always returns a fixed fee amount for testing
     * @return Fixed fee amount for testing
     */
    function quoteDispatch(
        uint32 /* _destinationDomain */,
        bytes32 /* _recipient */,
        bytes calldata /* _message */
    ) external pure returns (uint256) {
        // Return a fixed fee for testing purposes
        return FEE;
    }

    /**
     * @notice Simulate message receipt for testing purposes
     * @dev Allows tests to trigger a message receipt simulation
     * @param _origin Origin domain (chain ID)
     * @param _sender Address that sent the message
     * @param _recipient Address that should receive the message
     * @param _message Message body
     */
    function simulateMessageReceived(
        uint32 _origin,
        address _sender,
        address _recipient,
        bytes calldata _message
    ) external {
        // Convert the sender address to bytes32 for the recipient's handle function
        bytes32 sender = _sender.addressToBytes32();

        // Call the recipient's handle function with empty read operations
        IMetalayerRecipientMock(_recipient).handle(
            _origin,
            sender,
            _message,
            new ReadOperation[](0),
            new bytes[](0)
        );
    }
}

/**
 * @title IMetalayerRecipientMock
 * @notice A simplified interface for MetalayerRecipient for testing purposes
 */
interface IMetalayerRecipientMock {
    function handle(
        uint32 origin,
        bytes32 sender,
        bytes calldata message,
        ReadOperation[] calldata operations,
        bytes[] calldata operationsData
    ) external payable;
}
