// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReadOperation, IMetalayerRecipient} from "../interfaces/IMetalayerRecipient.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";

contract TestRouter {
    using TypeCasts for bytes32;

    address public processor;

    uint32 public destinationDomain;

    address public recipientAddress;

    bytes public messageBody;

    ReadOperation[] public reads;

    bool public dispatched;

    constructor(address _processor) {
        processor = _processor;
    }

    function dispatch(
        uint32 _destinationDomain,
        address _recipientAddress,
        ReadOperation[] memory _reads,
        bytes calldata _messageBody
    ) public payable returns (uint256) {
        destinationDomain = _destinationDomain;
        recipientAddress = _recipientAddress;
        messageBody = _messageBody;
        reads = _reads;
        dispatched = true;

        if (processor != address(0)) {
            process(_messageBody);
        }

        return (msg.value);
    }

    function process(bytes calldata _msg) public {
        IMetalayerRecipient(recipientAddress).handle(
            uint32(block.chainid), msg.sender, _msg, reads, new bytes[](reads.length)
        );
    }
}
