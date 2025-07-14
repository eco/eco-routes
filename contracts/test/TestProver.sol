/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "../prover/BaseProver.sol";
import {IProver} from "../interfaces/IProver.sol";

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

    function addProvenIntent(bytes32 _hash, address _claimant) public {
        _provenIntents[_hash] = ProofData({
            claimant: _claimant,
            destinationChainID: uint64(block.chainid)
        });
    }

    function addProvenIntentWithChain(
        bytes32 _hash,
        address _claimant,
        uint96 _destinationChainId
    ) public {
        _provenIntents[_hash] = ProofData({
            claimant: _claimant,
            destinationChainID: uint64(_destinationChainId)
        });
    }

    function getProofType() external pure override returns (string memory) {
        return "storage";
    }

    function prove(
        address _sender,
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        bytes32[] calldata _claimants,
        bytes calldata _data
    ) external payable override {
        args = ArgsCheck({
            sender: _sender,
            sourceChainId: _sourceChainId,
            data: _data,
            value: msg.value
        });
        argIntentHashes = _intentHashes;
        argClaimants = _claimants;
    }
}
