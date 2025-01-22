// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReadOperation} from "./IMetalayerRecipient.sol";

interface IMetalayerRouter {
    /**
     * @notice Dispatches a message to the destination domain & recipient with the given reads and write.
     * @param _destinationDomain Domain of destination chain
     * @param _recipientAddress Address of recipient on destination chain
     * @param _reads Read operations
     * @param _writeCallData The raw bytes to be called on the recipient address.
     */
    function dispatch(
        uint32 _destinationDomain,
        address _recipientAddress,
        ReadOperation[] memory _reads,
        bytes memory _writeCallData
    ) external payable;
}
