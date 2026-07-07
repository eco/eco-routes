/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BasePolicy} from "../prover/BasePolicy.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {IMessageBridgePolicy} from "../interfaces/IMessageBridgePolicy.sol";
import {IntentLib} from "../types/Intent.sol";

/**
 * @title TestPolicy
 * @notice Simple test implementation of BasePolicy for unit testing
 * @dev Focuses on testing the core prove interface and proof storage
 */
contract TestPolicy is BasePolicy {
    // Track the last prove() call for testing
    struct ArgsCheck {
        address sender;
        uint64 sourceChainId;
        bytes data;
        uint256 value;
    }

    ArgsCheck public args;
    uint256 public proveCallCount;

    // Store last processed proofs for test verification
    bytes32[] public argIntentHashes;
    bytes32[] public argClaimants;

    constructor(address _portal) BasePolicy(_portal) {}

    function version() external pure returns (string memory) {
        return "1.8.14-e2c12e7";
    }

    /**
     * @notice Helper to manually add a proven intent (hash-only fact) for testing
     * @param _hash Intent hash
     * @param _fulfillmentHash Fulfillment commitment
     * @param _destination Destination chain id
     */
    function addProvenIntent(
        bytes32 _hash,
        bytes32 _fulfillmentHash,
        uint64 _destination
    ) public {
        _provenIntents[_hash] = ProofData({
            destination: _destination,
            fulfillmentHash: _fulfillmentHash
        });
    }

    function addProvenIntentWithChain(
        bytes32 _hash,
        bytes32 _fulfillmentHash,
        uint64 _destination
    ) public {
        _provenIntents[_hash] = ProofData({
            destination: _destination,
            fulfillmentHash: _fulfillmentHash
        });
    }

    /**
     * @notice Convenience helper: computes and stores the fulfillment commitment for a preimage
     * @param _hash Intent hash
     * @param _claimant Claimant identifier committed in the fulfillment
     * @param _fulfilled Per-leg delivered amounts committed in the fulfillment
     * @param _destination Destination chain id
     */
    function addProvenFulfillment(
        bytes32 _hash,
        bytes32 _claimant,
        uint256[] memory _fulfilled,
        uint64 _destination
    ) public {
        _provenIntents[_hash] = ProofData({
            destination: _destination,
            fulfillmentHash: IntentLib.fulfillmentHash(
                _hash,
                _claimant,
                _fulfilled
            )
        });
    }

    function getProofType() external pure override returns (string memory) {
        return "storage";
    }

    /**
     * @notice Implementation of the dispatch-direction prove that tracks calls
     * @dev The prover now builds the wire message from its own destination fulfillment store, so it
     *      receives only the intent hashes. Records the call parameters and captures the
     *      (intentHash, claimant) pairs read from {_destFulfillment} for test verification.
     */
    function prove(
        address _sender,
        uint64 _sourceChainId,
        bytes32[] calldata _intentHashes,
        bytes calldata _data
    ) external payable override {
        // Track the call for testing
        args = ArgsCheck({
            sender: _sender,
            sourceChainId: _sourceChainId,
            data: _data,
            value: msg.value
        });
        proveCallCount++;

        delete argIntentHashes;
        delete argClaimants;

        uint256 len = _intentHashes.length;
        for (uint256 i = 0; i < len; i++) {
            bytes32 intentHash = _intentHashes[i];
            bytes32 claimantBytes = _destFulfillment[intentHash];
            if (claimantBytes == bytes32(0)) {
                revert IntentNotFulfilled(intentHash);
            }
            argIntentHashes.push(intentHash);
            argClaimants.push(claimantBytes);
        }
    }

    /**
     * @notice Test-only reception entrypoint mirroring the old prove-side processing
     * @dev The source-side reception logic ({_processIntentProofs}) is unchanged by the storage
     *      move — only its entrypoint did (production reception is `handle`/`_handleCrossChainMessage`).
     *      This shim lets the interface tests keep exercising that reception logic with a raw
     *      chain-id-prefixed message. Tracks the call parameters the same way the old prove did.
     */
    function receiveProofs(
        address _sender,
        uint64 _sourceChainId,
        bytes calldata _encodedProofs,
        bytes calldata _data
    ) external payable {
        // Track the call for testing
        args = ArgsCheck({
            sender: _sender,
            sourceChainId: _sourceChainId,
            data: _data,
            value: msg.value
        });
        proveCallCount++;

        // Skip the first 8 bytes (chain ID) and extract proofs for test verification
        if (_encodedProofs.length < 8) {
            revert IMessageBridgePolicy.InvalidProofMessage();
        }
        if ((_encodedProofs.length - 8) % 64 != 0) {
            revert IPolicy.ArrayLengthMismatch();
        }

        bytes calldata proofsData = _encodedProofs[8:];
        uint256 numPairs = proofsData.length / 64;
        delete argIntentHashes;
        delete argClaimants;

        for (uint256 i = 0; i < numPairs; i++) {
            uint256 offset = i * 64;
            argIntentHashes.push(bytes32(proofsData[offset:offset + 32]));
            argClaimants.push(bytes32(proofsData[offset + 32:offset + 64]));
        }

        // Process the encoded proofs to update internal state (pass without chain ID)
        _processIntentProofs(proofsData, _sourceChainId);
    }
}
