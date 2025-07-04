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
        address _inbox,
        uint32 _localDomain,
        address _xChainReader,
        address _prover
    ) BaseProver(_inbox) {
        LOCAL_DOMAIN = _localDomain;
        X_CHAIN_READER = IT1XChainReader(_xChainReader);
        PROVER = _prover;
    }

    function requestIntentProof(
        uint32 destinationDomain,
        bytes32 intentHash
    ) external {
        // create crosschain call data to check if intent is fulfilled
        bytes memory callData = abi.encodeWithSignature(
            "fulfilled(bytes32)",
            intentHash
        );

        // create read request
        IT1XChainReader.ReadRequest memory readRequest = IT1XChainReader
            .ReadRequest({
                destinationDomain: destinationDomain,
                targetContract: INBOX,
                gasLimit: 0,
                minBlock: 0,
                callData: callData,
                requester: msg.sender
            });

        bytes32 requestId = X_CHAIN_READER.requestRead(readRequest);

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
                gasLimit: 0,
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
        bytes calldata encodedProofOfRead
    ) external {
        // decode proof of read
        (bytes32 requestId, bytes memory result) = X_CHAIN_READER
            .verifyProofOfRead(encodedProofOfRead);

        // get intent hash from requestId
        IntentRequest memory intentRequest = readRequestToIntentRequest[
            requestId
        ];

        // delete intent request
        delete readRequestToIntentRequest[requestId];

        // check if intent is fufilled by decoding the result
        address claimant = abi.decode(result, (address));

        // check if intent is fufilled
        if (claimant == address(0)) {
            revert IntentNotFufilled();
        }

        // Create arrays for single intent proof processing
        bytes32[] memory hashes = new bytes32[](1);
        address[] memory claimants = new address[](1);
        hashes[0] = intentRequest.intentHash;
        claimants[0] = claimant;

        _processIntentProofs(
            uint96(intentRequest.destinationDomain),
            hashes,
            claimants
        );

        emit IntentProofVerified(requestId);
    }

    function handleReadResultWithProofBatch(
        bytes calldata encodedProofOfRead
    ) external {
        // decode proof of read
        (bytes32 requestId, bytes memory result) = X_CHAIN_READER
            .verifyProofOfRead(encodedProofOfRead);

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
            uint96(intentBatchRequest.destinationDomain),
            intentBatchRequest.intentHashes,
            claimants
        );
    }

    function challengeIntentProof(Intent calldata _intent) public {
        bytes32 intentHash = keccak256(
            abi.encodePacked(
                keccak256(abi.encode(_intent.route)),
                keccak256(abi.encode(_intent.reward))
            )
        );
        uint96 trueDestinationChainID = uint96(_intent.route.destination);

        ProofData storage proofData = _provenIntents[intentHash];

        if (trueDestinationChainID != proofData.destinationChainID) {
            if (proofData.destinationChainID != 0) {
                proofData.claimant = address(0);
                emit BadProofCleared(intentHash);
            }

            proofData.destinationChainID = trueDestinationChainID;
        }
    }

    function getProofType() public pure override returns (string memory) {
        return "t1";
    }

    // destination side of the proof //

    /**
     * @notice Gets claimant addresses for a batch of intents from local inbox
     * @param _intentHashes Array of intent hashes to check
     * @return claimants Array of claimant addresses (zero address if not fulfilled)
     */
    function fulfilledBatch(
        bytes32[] calldata _intentHashes
    ) external view returns (address[] memory claimants) {
        uint256 size = _intentHashes.length;
        claimants = new address[](size);

        for (uint256 i = 0; i < size; i++) {
            claimants[i] = Inbox(payable(INBOX)).fulfilled(_intentHashes[i]);
        }

        return claimants;
    }

    function prove(
        address _sender,
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        bytes calldata _data
    ) external payable override {
        // we don't need to do anything here because we are using pull based verification
        // we will just request the proof and then handle the result in the handleReadResultWithProof function
    }
}
