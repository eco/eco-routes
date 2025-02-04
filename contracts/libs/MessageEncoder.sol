// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ISemver} from "../interfaces/ISemver.sol";

abstract contract MessageEncoder {
    enum MessageType {
        STANDARD,
        COMPRESSED
    }

    function _getRootHash(
        bytes32[] memory intentHashes,
        address[] memory claimants
    ) internal pure returns (bytes32 rootHash) {
        bytes memory messageBody = abi.encode(intentHashes, claimants);
        rootHash = keccak256(messageBody);
    }

    function _encodeMessage(
        MessageType messageType,
        bytes memory message
    ) internal pure returns (bytes memory) {
        return abi.encode(messageType, message);
    }

    function _decodeMessage(
        bytes memory message
    ) internal pure returns (MessageType, bytes memory) {
        return abi.decode(message, (MessageType, bytes));
    }
}
