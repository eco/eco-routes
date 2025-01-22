// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity >=0.6.11;

/**
 * @notice Struct defining a cross-chain read operation
 * @param sourceChainId Domain of the chain to read from
 * @param sourceContract Contract address to read from as address
 * @param callDataLength Length of the call data
 * @param callData The encoded function call data
 */
struct ReadOperation {
    uint32 sourceChainId;
    address sourceContract;
    bytes callData;
}

interface IMetalayerRecipient {
    // Here, _readResults will be the results of every read in the message, in order. This will be input by the relayer.
    function handle(
        uint32 _chainId,
        address _sender,
        bytes calldata _message, // The body of the Metalayer message, or writeCallData.
        ReadOperation[] calldata _reads,
        bytes[] calldata _readResults
    ) external payable;
}
