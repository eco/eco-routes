/* -*- c-basic-offset: 4 -*- */
/* solhint-disable gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IMessageRecipient} from "@hyperlane-xyz/core/contracts/interfaces/IMessageRecipient.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {IPostDispatchHook} from "@hyperlane-xyz/core/contracts/interfaces/hooks/IPostDispatchHook.sol";

// Create a test extension of IMessageRecipient for whitelist testing
interface IMessageRecipientExt is IMessageRecipient {
    function addWhitelistForTest(address _address) external;
}

contract TestMailbox {
    using TypeCasts for bytes32;
    using TypeCasts for address;

    address public processor;

    uint32 public destinationDomain;

    bytes32 public recipientAddress;

    bytes public messageBody;

    bytes public metadata;

    address public relayer;

    bool public dispatched;

    bool public dispatchedWithRelayer;

    uint256 public constant FEE = 100000;

    constructor(address _processor) {
        processor = _processor;
    }

    function dispatch(
        uint32 _destinationDomain,
        bytes32 _recipientAddress,
        bytes calldata _messageBody,
        bytes calldata _metadata,
        IPostDispatchHook _relayer
    ) public payable returns (uint256) {
        destinationDomain = _destinationDomain;
        recipientAddress = _recipientAddress;
        messageBody = _messageBody;
        metadata = _metadata;
        relayer = address(_relayer);

        dispatchedWithRelayer = true;
        dispatched = true;

        // For testing purposes, try to whitelist the target contract in itself first
        try
            IMessageRecipientExt(recipientAddress.bytes32ToAddress())
                .addWhitelistForTest(recipientAddress.bytes32ToAddress())
        {} catch {}

        // Now process the message, which should work because we've added the processor to the whitelist
        if (processor != address(0)) {
            try
                IMessageRecipient(recipientAddress.bytes32ToAddress()).handle(
                    uint32(block.chainid),
                    // Important: For tests, we use the processor (in constructor)
                    // as the sender. In a real implementation, this would be the prover's address
                    // on the source chain, which should be whitelisted.
                    processor.addressToBytes32(),
                    _messageBody
                )
            {} catch {}
        }

        if (msg.value < FEE) {
            revert("no");
        }

        return (msg.value);
    }

    function process(bytes calldata _msg) public {
        // For tests, we can use this to simulate handling a message
        IMessageRecipient(recipientAddress.bytes32ToAddress()).handle(
            uint32(block.chainid),
            processor.addressToBytes32(),
            _msg
        );
    }

    /**
     * @notice Set the processor address for testing
     * @param _processor New processor address
     */
    function setProcessor(address _processor) public {
        processor = _processor;
    }

    function quoteDispatch(
        uint32,
        bytes32,
        bytes calldata
    ) public pure returns (bytes32) {
        return bytes32(FEE);
    }

    function quoteDispatch(
        uint32,
        bytes32,
        bytes calldata,
        bytes calldata,
        address
    ) public pure returns (bytes32) {
        return bytes32(FEE);
    }

    function defaultHook() public pure returns (IPostDispatchHook) {
        return IPostDispatchHook(address(0));
    }
}
