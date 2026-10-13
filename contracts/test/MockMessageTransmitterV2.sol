// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMessageHandlerV2} from "../interfaces/cctp/IMessageHandlerV2.sol";

/**
 * @notice Test transmitter: records the last sendMessage and delivers to a
 *         recipient the way MessageTransmitterV2.receiveMessage does (no
 *         attestation check; tests choose sourceDomain/sender/finality).
 */
contract MockMessageTransmitterV2 {
    uint32 public immutable localDomain;

    uint256 public sendCount;
    uint32 public lastDestinationDomain;
    bytes32 public lastRecipient;
    bytes32 public lastDestinationCaller;
    uint32 public lastMinFinalityThreshold;
    bytes public lastMessageBody;
    address public lastSender;

    constructor(uint32 _localDomain) {
        localDomain = _localDomain;
    }

    function sendMessage(
        uint32 destinationDomain,
        bytes32 recipient,
        bytes32 destinationCaller,
        uint32 minFinalityThreshold,
        bytes calldata messageBody
    ) external {
        require(destinationDomain != localDomain, "Domain is local domain");
        require(recipient != bytes32(0), "Recipient must be nonzero");
        sendCount++;
        lastDestinationDomain = destinationDomain;
        lastRecipient = recipient;
        lastDestinationCaller = destinationCaller;
        lastMinFinalityThreshold = minFinalityThreshold;
        lastMessageBody = messageBody;
        lastSender = msg.sender;
    }

    /// @dev Mirrors the transmitter's dispatch rule: < 2000 → Unfinalized.
    function deliver(
        address recipient,
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata body
    ) external returns (bool) {
        bool ok = finalityThresholdExecuted < 2000
            ? IMessageHandlerV2(recipient).handleReceiveUnfinalizedMessage(
                sourceDomain,
                sender,
                finalityThresholdExecuted,
                body
            )
            : IMessageHandlerV2(recipient).handleReceiveFinalizedMessage(
                sourceDomain,
                sender,
                finalityThresholdExecuted,
                body
            );
        require(ok, "Handler returned false");
        return ok;
    }
}
