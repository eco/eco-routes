/* -*- c-basic-offset: 4 -*- */
/* solhint-disable gas-custom-errors */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {IMetalayerRecipient, ReadOperation} from "@metalayer/contracts/src/interfaces/IMetalayerRecipient.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {IPostDispatchHook} from "@hyperlane-xyz/core/contracts/interfaces/hooks/IPostDispatchHook.sol";

contract TestMetaRouter {
    using TypeCasts for bytes32;
    using TypeCasts for address;

    address public processor;

    uint32 public destinationDomain;

    address public recipientAddress;

    bytes public messageBody;

    bytes public metadata;

    address public relayer;

    bool public dispatched;

    bool public dispatchedWithRelayer;

    uint256 public constant FEE = 100000;

    enum FinalityState {
        INSTANT,
        FINAL
    }

    constructor(address _processor) {
        processor = _processor;
    }

    function dispatch(
        uint32 _destinationDomain,
        address _recipientAddress,
        ReadOperation[] memory _reads,
        bytes memory _writeCallData,
        FinalityState _finalityState,
        uint256 _gasLimit
    ) external payable returns (uint256) {
        destinationDomain = _destinationDomain;
        recipientAddress = _recipientAddress;
        messageBody = _writeCallData;
        dispatched = true;

        if (processor != address(0)) {
            process(_writeCallData);
        }

        if (msg.value < FEE) {
            revert("no");
        }

        return (msg.value);
    }

    function process(bytes memory _msg) public {
        ReadOperation[] memory readOps;
        bytes[] memory readResponses;

        IMetalayerRecipient(recipientAddress).handle(
            uint32(block.chainid),
            msg.sender.addressToBytes32(),
            _msg,
            readOps,
            readResponses
        );
    }

    function quoteDispatch(
        uint32,
        bytes32,
        bytes memory
    ) public pure returns (uint256) {
        return FEE;
    }
}
