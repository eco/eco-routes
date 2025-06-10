// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {T1XChainReader} from "t1/contracts/src/libraries/xChain/T1XChainReader.sol";
import {Inbox} from "../Inbox.sol";

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
    T1XChainReader public immutable X_CHAIN_READER;

    // state variables
    mapping(bytes32 => bytes32) public readRequestToOrderId;

    //events
    event IntentProofRequested(bytes32 indexed orderId, bytes32 indexed requestId);


    constructor(address _inbox, uint32 _localDomain, address _xChainReader) BaseProver(_inbox) {
        LOCAL_DOMAIN = _localDomain;
        X_CHAIN_READER = T1XChainReader(_xChainReader);
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
        T1XChainReader.ReadRequest memory readRequest = T1XChainReader.ReadRequest({
            destinationDomain: destinationDomain,
            targetContract: INBOX,
            gasLimit: gasLimit,
            minBlock: 0,
            callData: callData
        });

        bytes32 requestId = X_CHAIN_READER.requestRead{ value: msg.value }(readRequest);

        readRequestToOrderId[requestId] = intentHash;

        emit IntentProofRequested(intentHash, requestId);
    }

}
