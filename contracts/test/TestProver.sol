/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "../prover/BaseProver.sol";

contract TestProver is BaseProver {
    struct ArgsCheck {
        address sender;
        uint256 sourceChainId;
        bytes data;
        uint256 value;
    }

    ArgsCheck public args;
    bytes32[] public argIntentHashes;
    bytes32[] public argClaimants;

    constructor(address _portal) BaseProver(_portal) {}

    function version() external pure returns (string memory) {
        return "1.8.14-e2c12e7";
    }

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

    function prove(
        address _sender,
        uint256 _sourceChainId,
        bytes calldata _encodedProofs,
        bytes calldata _data
    ) external payable override {
        // Extract intentHashes and claimants from encodedProofs
        (
            bytes32[] memory intentHashes,
            bytes32[] memory claimants
        ) = _extractFromEncodedProofs(_encodedProofs);

        args = ArgsCheck({
            sender: _sender,
            sourceChainId: _sourceChainId,
            data: _data,
            value: msg.value
        });
        argIntentHashes = intentHashes;
        argClaimants = claimants;
    }

    /**
     * @notice Extracts intentHashes and claimants from encodedProofs
     * @dev encodedProofs contains (claimant, intentHash) pairs as bytes, where each pair is 64 bytes
     * @param encodedProofs Encoded (claimant, intentHash) pairs as bytes
     * @return intentHashes Array of intent hashes
     * @return claimants Array of claimant addresses as bytes32
     */
    function _extractFromEncodedProofs(
        bytes calldata encodedProofs
    )
        internal
        pure
        returns (bytes32[] memory intentHashes, bytes32[] memory claimants)
    {
        // Ensure data length is multiple of 64 bytes (32 for claimant + 32 for hash)
        if (encodedProofs.length == 0) {
            return (new bytes32[](0), new bytes32[](0));
        }

        if (encodedProofs.length % 64 != 0) {
            revert ArrayLengthMismatch();
        }

        uint256 numPairs = encodedProofs.length / 64;
        intentHashes = new bytes32[](numPairs);
        claimants = new bytes32[](numPairs);

        for (uint256 i = 0; i < numPairs; i++) {
            uint256 offset = i * 64;

            // Extract claimant and intentHash using slice
            claimants[i] = bytes32(encodedProofs[offset:offset + 32]);
            intentHashes[i] = bytes32(encodedProofs[offset + 32:offset + 64]);
        }
    }
}
