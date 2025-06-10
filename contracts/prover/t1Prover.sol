// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IT1XChainReader} from "../interfaces/t1/IT1XChainReader.sol";
import {Inbox} from "../Inbox.sol";
import {BaseProver} from "./BaseProver.sol";

/**
 * @title T1Prover
 * @author t1 Labs
 * @notice Cross-chain prover implementation using t1's pull-based verification system
 * @dev Extends BaseProver with t1's cross-chain read capabilities for verifying intents
 * @dev Enables efficient verification of cross-chain intents via pull based verification
 */

contract T1Prover is BaseProver {

    //constants
    uint32 public immutable LOCAL_DOMAIN;
    IT1XChainReader public immutable X_CHAIN_READER;

    //structs
    struct IntentRequest {
        uint32 destinationDomain;
        bytes32 intentHash;
    }

    // state variables
    mapping(bytes32 => IntentRequest) public readRequestToIntentRequest;

    //events
    event IntentProofRequested(bytes32 indexed orderId, bytes32 indexed requestId);
    event IntentProofVerified(bytes32 indexed intentHash, address indexed claimant);

    //errors
    error IntentNotFufilled();

    constructor(address _inbox, uint32 _localDomain, address _xChainReader) BaseProver(_inbox) {
        LOCAL_DOMAIN = _localDomain;
        X_CHAIN_READER = IT1XChainReader(_xChainReader);
    }

    function requestIntentProof(
        uint32 destinationDomain,
        uint256 gasLimit,
        bytes32 intentHash
    ) external {

        // create crosschain call data
        bytes memory callData = abi.encodeWithSelector(
            Inbox.fulfilled.selector,
            intentHash
        );

        // create read request
        IT1XChainReader.ReadRequest memory readRequest = IT1XChainReader.ReadRequest({
            destinationDomain: destinationDomain,
            targetContract: INBOX,
            gasLimit: gasLimit,
            minBlock: 0,
            callData: callData
        });

        bytes32 requestId = X_CHAIN_READER.requestRead{ value: msg.value }(readRequest);

        readRequestToIntentRequest[requestId] = IntentRequest({
            destinationDomain: destinationDomain,
            intentHash: intentHash
        });

        emit IntentProofRequested(intentHash, requestId);
    }

    // can be extended to handle multiple proofs at once eventually like Polymer
    function handleReadResultWithProof(bytes calldata encodedProofOfRead) external {
        // decode proof of read
        (bytes32 requestId, bytes memory result) = X_CHAIN_READER.verifyProofOfRead(encodedProofOfRead);

        // get intent hash from requestId
        IntentRequest memory intentRequest = readRequestToIntentRequest[requestId];

        // delete intent request
        delete readRequestToIntentRequest[requestId];

        // check if intent is fufilled by decoding the result 
        (address claimant) = abi.decode(result, (address));

        // check if intent is fufilled
        if (claimant == address(0)) {
            revert IntentNotFufilled();
        }

        // Create arrays for single intent proof processing
        bytes32[] memory hashes = new bytes32[](1);
        address[] memory claimants = new address[](1);
        hashes[0] = intentRequest.intentHash;
        claimants[0] = claimant;

        _processIntentProofs(uint96(intentRequest.destinationDomain), hashes, claimants);

        emit IntentProofVerified(intentRequest.intentHash, claimant);
    }
}
