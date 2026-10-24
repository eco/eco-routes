// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IMessageTransmitterV2
 * @notice The subset of Circle's MessageTransmitterV2 that CCTPProver uses.
 *         Mirrors circlefin/evm-cctp-contracts commit a92a2b4e src/v2/MessageTransmitterV2.sol.
 * @dev The header `sender` of a sent message is msg.sender left-padded to
 *      bytes32. destinationCaller == bytes32(0) lets anyone call receiveMessage.
 */
interface IMessageTransmitterV2 {
    function sendMessage(
        uint32 destinationDomain,
        bytes32 recipient,
        bytes32 destinationCaller,
        uint32 minFinalityThreshold,
        bytes calldata messageBody
    ) external;

    function receiveMessage(
        bytes calldata message,
        bytes calldata attestation
    ) external returns (bool success);

    function localDomain() external view returns (uint32);
}
