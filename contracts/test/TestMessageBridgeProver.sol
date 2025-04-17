// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "../prover/BaseProver.sol";
import {MessageBridgeProver} from "../prover/MessageBridgeProver.sol";

/**
 * @title TestMessageBridgeProver
 * @notice Test implementation of MessageBridgeProver for unit testing
 * @dev Provides dummy implementations of required methods and adds helper methods for testing
 */
contract TestMessageBridgeProver is MessageBridgeProver {
    bool public dispatched = false;
    uint256 public lastSourceChainId;
    bytes32[] public lastIntentHashes;
    address[] public lastClaimants;
    address public lastSourceChainProver;
    bytes public lastData;

    uint256 public feeAmount = 100000;

    // No events needed for testing

    constructor(address[] memory _provers) {
        // Add itself to the whitelist by default
        proverWhitelist[address(this)] = true;
        for (uint256 i = 0; i < _provers.length; i++) {
            proverWhitelist[_provers[i]] = true;
        }
    }

    function addWhitelistedProver(address _prover) external {
        proverWhitelist[_prover] = true;
    }

    /**
     * @notice Mock implementation of initiateProving
     * @dev Records arguments and marks dispatched = true
     */
    function initiateProving(
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        address _sourceChainProver,
        bytes calldata _data
    ) external payable override {
        dispatched = true;
        lastSourceChainId = _sourceChainId;

        // Store arrays for later verification
        delete lastIntentHashes;
        delete lastClaimants;

        for (uint256 i = 0; i < _intentHashes.length; i++) {
            lastIntentHashes.push(_intentHashes[i]);
        }

        for (uint256 i = 0; i < _claimants.length; i++) {
            lastClaimants.push(_claimants[i]);
        }

        lastSourceChainProver = _sourceChainProver;
        lastData = _data;
    }

    /**
     * @notice Mock implementation of fetchFee
     * @dev Returns a fixed fee amount for testing
     */
    function fetchFee(
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
        address _sourceChainProver,
        bytes calldata _data
    ) public view override returns (uint256) {
        return feeAmount;
    }

    /**
     * @notice Helper method to manually add proven intents for testing
     * @param _hash Intent hash
     * @param _claimant Claimant address
     */
    function addProvenIntent(bytes32 _hash, address _claimant) public {
        provenIntents[_hash] = _claimant;
    }

    /**
     * @notice Implementation of getProofType from IProver
     * @return String indicating the proving mechanism used
     */
    function getProofType() external pure override returns (string memory) {
        return "TestMessageBridgeProver";
    }

    function version() external pure returns (string memory) {
        return "test";
    }
}
