// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IT1XChainReader} from "../interfaces/t1/IT1XChainReader.sol";
import {Inbox} from "../Inbox.sol";
import {BaseProver} from "./BaseProver.sol";
import {Intent} from "../types/Intent.sol";
import {Semver} from "../libs/Semver.sol";

/**
 * @title T1Prover
 * @author t1 Labs
 * @notice Cross-chain prover implementation using t1's pull-based verification system
 * @dev Extends BaseProver with t1's cross-chain read capabilities for verifying intents
 * @dev Enables efficient verification of cross-chain intents via pull based verification
 */

contract T1Prover is BaseProver, Semver {
    //constants
    uint32 public immutable LOCAL_DOMAIN;
    IT1XChainReader public immutable X_CHAIN_READER;
    address public immutable PROVER;

    //structs
    struct IntentRequest {
        uint32 destinationDomain;
        bytes32 intentHash;
    }

    struct IntentBatchRequest {
        uint32 destinationDomain;
        bytes32[] intentHashes;
    }

    // state variables
    mapping(bytes32 => IntentRequest) public readRequestToIntentRequest;
    mapping(bytes32 => IntentBatchRequest)
        public readRequestToIntentBatchRequest;

    //events
    event IntentProofRequested(
        bytes32 indexed orderId,
        bytes32 indexed requestId
    );
    event IntentBatchProofRequested(
        bytes32[] indexed intentHashes,
        bytes32 indexed requestId
    );
    event IntentProofVerified(bytes32 indexed requestId);
    event BadProofCleared(bytes32 indexed intentHash);

    //errors
    error IntentNotFufilled();

    constructor(
        address _portal,
        uint32 _localDomain,
        address _xChainReader,
        address _prover
    ) BaseProver(_portal) {
        LOCAL_DOMAIN = _localDomain;
        X_CHAIN_READER = IT1XChainReader(_xChainReader);
        PROVER = _prover;
    }

    function requestIntentProof(
        uint32 destinationDomain,
        bytes32 intentHash
    ) external payable {
        // create crosschain call data to check if intent is fulfilled
        bytes memory callData = abi.encodeWithSignature(
            "fulfilled(bytes32)",
            intentHash
        );

        // create read request
        IT1XChainReader.ReadRequest memory readRequest = IT1XChainReader
            .ReadRequest({
                destinationDomain: destinationDomain,
                targetContract: PORTAL,
                minBlock: 0,
                callData: callData,
                requester: msg.sender
            });

        bytes32 requestId = X_CHAIN_READER.requestRead{value: msg.value}(
            readRequest
        );

        readRequestToIntentRequest[requestId] = IntentRequest({
            destinationDomain: destinationDomain,
            intentHash: intentHash
        });

        emit IntentProofRequested(intentHash, requestId);
    }

    function requestIntentProofBatch(
        uint32 destinationDomain,
        bytes32[] calldata intentHashes
    ) external {
        // create crosschain call data to check if intent is fulfilled
        bytes memory callData = abi.encodeWithSelector(
            this.fulfilledBatch.selector,
            intentHashes
        );

        // create read request
        IT1XChainReader.ReadRequest memory readRequest = IT1XChainReader
            .ReadRequest({
                destinationDomain: destinationDomain,
                targetContract: PROVER,
                minBlock: 0,
                callData: callData,
                requester: msg.sender
            });

        bytes32 requestId = X_CHAIN_READER.requestRead(readRequest);

        // fix this to handle multiple intents
        readRequestToIntentBatchRequest[requestId] = IntentBatchRequest({
            destinationDomain: destinationDomain,
            intentHashes: intentHashes
        });

        emit IntentBatchProofRequested(intentHashes, requestId);
    }

    // can be extended to handle multiple proofs at once eventually like Polymer
    function handleReadResultWithProof(
        bytes calldata encodedProofOfRead,
        bytes calldata result
    ) external {
        // decode proof of read
        bytes32 requestId = X_CHAIN_READER
            .verifyProofOfReadWithResult(encodedProofOfRead, result);

        // get intent hash from requestId
        IntentRequest memory intentRequest = readRequestToIntentRequest[
            requestId
        ];

        // delete intent request
        delete readRequestToIntentRequest[requestId];

        // check if intent is fufilled by decoding the result
        (,bytes32 claimant) = abi.decode(result, (bytes32, bytes32));

        // check if intent is fufilled
        if (claimant == bytes32(0)) {
            revert IntentNotFufilled();
        }

        _processIntentProofs(
            result,
            uint256(intentRequest.destinationDomain)
        );

        emit IntentProofVerified(requestId);
    }

    function handleReadResultWithProofBatch(
        bytes calldata encodedProofOfRead,
        bytes calldata result
    ) external {
        // decode proof of read
        bytes32 requestId = X_CHAIN_READER
            .verifyProofOfReadWithResult(encodedProofOfRead, result);

        // get intent hashes from requestId
        IntentBatchRequest
            memory intentBatchRequest = readRequestToIntentBatchRequest[
                requestId
            ];

        // delete intent hashes
        delete readRequestToIntentBatchRequest[requestId];

        // decode result
        address[] memory claimants = abi.decode(result, (address[]));

        // for each intent hash, check if the claimant is zero address and if so, revert
        for (uint256 i = 0; i < intentBatchRequest.intentHashes.length; i++) {
            if (claimants[i] == address(0)) {
                revert IntentNotFufilled();
            }
        }

        _processIntentProofs(
            result,
            uint256(intentBatchRequest.destinationDomain)
        );
    }

    function challengeIntentProof(Intent calldata _intent) public {
        bytes32 intentHash = keccak256(
            abi.encodePacked(
                keccak256(abi.encode(_intent.route)),
                keccak256(abi.encode(_intent.reward))
            )
        );

        ProofData storage proofData = _provenIntents[intentHash];

        if (_intent.destination != proofData.destination) {
            if (proofData.destination != 0) {
                proofData.claimant = address(0);
                emit BadProofCleared(intentHash);
            }

            proofData.destination = _intent.destination;
        }
    }

    function getProofType() public pure override returns (string memory) {
        return "t1";
    }

    // destination side of the proof //

    /**
     * @notice Gets claimant addresses for a batch of intents from local inbox
     * @param _intentHashes Array of intent hashes to check
     * @return claimants Encoded array of intent hashes + claimant addresses (zero address if not fulfilled)
     */
    function fulfilledBatch(
        bytes32[] calldata _intentHashes
    ) external view returns (bytes[] memory claimants) {
        uint256 size = _intentHashes.length;
        claimants = new bytes[](size);

        for (uint256 i = 0; i < size; i++) {
            bytes32 claimaint = Inbox(payable(PORTAL)).fulfilled(_intentHashes[i]);
            claimants[i] = abi.encode(_intentHashes[i], claimaint);
        }

        return claimants;
    }

    function prove(
        address sender,
        uint256 sourceChainId,
        bytes calldata encodedProofs,
        bytes calldata data
    ) external payable override {
        // we don't need to do anything here because we are using pull based verification
        // we will just request the proof and then handle the result in the handleReadResultWithProof function
    }
}
