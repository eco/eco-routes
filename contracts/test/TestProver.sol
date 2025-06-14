/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "../prover/BaseProver.sol";
import {IProver} from "../interfaces/IProver.sol";
import {Intent} from "../types/Intent.sol";

contract TestProver is BaseProver {
    struct ArgsCheck {
        address sender;
        uint256 sourceChainId;
        bytes data;
        uint256 value;
    }

    ArgsCheck public args;
    bytes32[] public argIntentHashes;
    address[] public argClaimants;

    bytes32 public hashOfChallengedIntent;

    constructor(address _inbox) BaseProver(_inbox) {}

    function version() external pure returns (string memory) {
        return "1.8.14-e2c12e7";
    }

    function addProvenIntent(
        bytes32 _hash,
        uint96 _destinationChainID,
        address _claimant
    ) public {
        _provenIntents[_hash].claimant = _claimant;
        _provenIntents[_hash].destinationChainID = _destinationChainID;
    }

    function getProofType() external pure override returns (string memory) {
        return "storage";
    }

    function prove(
        address _sender,
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
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

    function challengeIntentProof(Intent calldata _intent) external {
        hashOfChallengedIntent = keccak256(
            abi.encodePacked(
                keccak256(abi.encode(_intent.route)),
                keccak256(abi.encode(_intent.reward))
            )
        );
    }
}
