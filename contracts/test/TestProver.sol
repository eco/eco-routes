/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "../prover/BaseProver.sol";

/**
 * @title TestProver
 * @notice Simple test implementation of BaseProver for unit testing
 * @dev Focuses on testing the core prove interface and proof storage
 */
contract TestProver is BaseProver {
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

    constructor(address _portal) BaseProver(_portal) {}

    function version() external pure returns (string memory) {
        return "1.8.14-e2c12e7";
    }

    /**
     * @notice Helper to manually add proven intents for testing
     */
    function addProvenIntent(
        bytes32 _hash,
        address _claimant,
        uint64 _destination
    ) public {
        _provenIntents[_hash] = ProofData({
            claimant: _claimant,
            destination: _destination
        });
    }

    function addProvenIntentWithChain(
        bytes32 _hash,
        address _claimant,
        uint96 _destination
    ) public {
        _provenIntents[_hash] = ProofData({
            claimant: _claimant,
            destination: uint64(_destination)
        });
    }

    function getProofType() external pure override returns (string memory) {
        return "storage";
    }

    /**
     * @notice Implementation of prove that tracks calls and processes proofs
     * @dev Simply records the call parameters and processes the encoded proofs
     */
    function prove(
        address _sender,
        uint64 _sourceChainId,
        bytes calldata _encodedProofs,
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

        // Extract and store proofs for test verification
        uint256 numPairs = _encodedProofs.length / 64;
        delete argIntentHashes;
        delete argClaimants;

        for (uint256 i = 0; i < numPairs; i++) {
            uint256 offset = i * 64;
            argIntentHashes.push(bytes32(_encodedProofs[offset:offset + 32]));
            argClaimants.push(bytes32(_encodedProofs[offset + 32:offset + 64]));
        }

        // Process the encoded proofs to update internal state
        _processIntentProofs(_encodedProofs, _sourceChainId);
    }
}
