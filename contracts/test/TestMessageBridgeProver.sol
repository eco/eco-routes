// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "../prover/BaseProver.sol";
import {MessageBridgeProver} from "../prover/MessageBridgeProver.sol";
import {IProver} from "../interfaces/IProver.sol";
import {IMessageBridgeProver} from "../interfaces/IMessageBridgeProver.sol";
import {MinimalRoute} from "../types/Intent.sol";

/**
 * @title TestMessageBridgeProver
 * @notice Test implementation of MessageBridgeProver for unit testing
 * @dev Provides dummy implementations of required methods and adds helper methods for testing
 */
contract TestMessageBridgeProver is MessageBridgeProver {
    bool public dispatched = false;
    uint256 public lastSourceChainID;
    MinimalRoute[] public lastMinimalRoutes;
    bytes32[] public lastRewardHashes;
    address[] public lastClaimants;
    bytes32 public lastSourceChainProver;
    bytes public lastData;

    uint256 public feeAmount = 100000;

    // No events needed for testing

    constructor(
        address _inbox,
        address[] memory _provers,
        uint256 _gasLimit
    ) MessageBridgeProver(_inbox, _provers, _gasLimit) {}

    /**
     * @notice Legacy test method for backward compatibility
     * @dev This method exists only for test compatibility with old code
     * In production code, always use isWhitelisted() directly instead of this method
     * @param _prover Address of the prover to test whitelisting for
     * @return Whether the prover is whitelisted
     * @custom:deprecated Use isWhitelisted() instead
     */
    function isAddressWhitelisted(
        address _prover
    ) external view returns (bool) {
        return isWhitelisted(_prover);
    }

    /**
     * @notice Test helper to access the whitelist
     * @return Array of all addresses in the whitelist
     */
    function getWhitelistedAddresses()
        external
        view
        returns (address[] memory)
    {
        return getWhitelist();
    }

    // No custom events needed for testing

    /**
     * @notice Mock implementation of initiateProving
     * @dev Records arguments and marks dispatched = true
     */
    function prove(
        address /* _sender */,
        uint256 _sourceChainID,
        MinimalRoute[] calldata _minimalRoutes,
        bytes32[] calldata _rewardHashes,
        address[] calldata _claimants,
        bytes calldata _data
    ) external payable override {
        dispatched = true;
        lastSourceChainID = _sourceChainID;

        // Store arrays for later verification
        delete lastRewardHashes;
        delete lastClaimants;

        for (uint256 i = 0; i < _rewardHashes.length; i++) {
            lastRewardHashes.push(_rewardHashes[i]);
        }

        for (uint256 i = 0; i < _claimants.length; i++) {
            lastClaimants.push(_claimants[i]);
        }

        for (uint256 i = 0; i < _minimalRoutes.length; i++) {
            lastMinimalRoutes.push(_minimalRoutes[i]);
        }

        lastSourceChainProver = abi.decode(_data, (bytes32));
        lastData = _data;
    }

    /**
     * @notice Mock implementation of fetchFee
     * @dev Returns a fixed fee amount for testing
     */
    function fetchFee(
        uint256 /* _sourceChainID */,
        MinimalRoute[] calldata /* _minimalRoutes */,
        bytes32[] calldata /* _rewardHashes */,
        address[] calldata /* _claimants */,
        bytes calldata /* _data */
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
