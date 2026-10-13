// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IMessageHandlerV2
 * @notice Recipient callback that Circle's MessageTransmitterV2 invokes from
 *         receiveMessage. Mirrors circlefin/evm-cctp-contracts commit a92a2b4e
 *         src/interfaces/v2/IMessageHandlerV2.sol.
 * @dev The transmitter calls the Unfinalized variant when
 *      finalityThresholdExecuted < 2000 and the Finalized variant otherwise,
 *      and requires a `true` return.
 */
interface IMessageHandlerV2 {
    function handleReceiveFinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) external returns (bool);

    function handleReceiveUnfinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 finalityThresholdExecuted,
        bytes calldata messageBody
    ) external returns (bool);
}
