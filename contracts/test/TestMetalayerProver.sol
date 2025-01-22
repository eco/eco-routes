// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/SimpleProver.sol";
import "../interfaces/IMetalayerRecipient.sol";

contract TestMetalayerProver is SimpleProver, IMetalayerRecipient {
    event MessageReceived(uint32 chainId, address sender, bytes message, ReadOperation[] reads, bytes[] readResults);

    function version() external pure returns (string memory) {
        return "0.0.618-beta";
    }

    function handle(
        uint32 _chainId,
        address _sender,
        bytes calldata _message,
        ReadOperation[] calldata _reads,
        bytes[] calldata _readResults
    ) external payable {
        emit MessageReceived(_chainId, _sender, _message, _reads, _readResults);

        // Decode the message and update provenIntents
        (bytes32[] memory hashes, address[] memory claimants) = abi.decode(_message, (bytes32[], address[]));

        for (uint256 i = 0; i < hashes.length; i++) {
            provenIntents[hashes[i]] = claimants[i];
            emit IntentProven(hashes[i], claimants[i]);
        }
    }

    function getProofType() external pure override returns (ProofType) {
        return ProofType.Metalayer;
    }
}
