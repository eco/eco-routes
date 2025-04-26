// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "../prover/BaseProver.sol";
import {MessageBridgeProver} from "../prover/MessageBridgeProver.sol";
import {IProver} from "../interfaces/IProver.sol";
import {IMessageBridgeProver} from "../interfaces/IMessageBridgeProver.sol";

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
    bytes32 public lastSourceChainProver;
    bytes public lastData;

    uint256 public feeAmount = 100000;

    // No events needed for testing

    constructor(
        address _inbox,
        IMessageBridgeProver.TrustedProver[] memory _provers,
        uint256 _gasLimit
    ) MessageBridgeProver(_inbox, _provers, _gasLimit) {}

    /**
     * @notice Add a prover to the whitelist for a specific chain
     * @param _chainId Chain ID where the prover is authorized
     * @param _prover Address of the prover to whitelist
     */
    function addWhitelistedProver(uint256 _chainId, address _prover) external {
        proverWhitelist[_chainId][_prover] = true;
        emit ProverWhitelisted(_chainId, _prover);
    }

    /**
     * @notice Remove a prover from the whitelist for a specific chain
     * @param _chainId Chain ID where the prover is authorized
     * @param _prover Address of the prover to remove from whitelist
     */
    function removeWhitelistedProver(
        uint256 _chainId,
        address _prover
    ) external {
        proverWhitelist[_chainId][_prover] = false;
        emit ProverWhitelistRemoved(_chainId, _prover);
    }

    /**
     * @notice Event emitted when a prover is removed from the whitelist
     * @param _chainId Chain ID where the prover was authorized
     * @param _prover Address of the prover removed from whitelist
     */
    event ProverWhitelistRemoved(
        uint256 indexed _chainId,
        address indexed _prover
    );

    /**
     * @notice Mock implementation of initiateProving
     * @dev Records arguments and marks dispatched = true
     */
    function sendProof(
        address /* _sender */,
        uint256 _sourceChainId,
        bytes32[] calldata _intentHashes,
        address[] calldata _claimants,
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

        lastSourceChainProver = abi.decode(_data, (bytes32));
        lastData = _data;
    }

    /**
     * @notice Mock implementation of fetchFee
     * @dev Returns a fixed fee amount for testing
     */
    function fetchFee(
        uint256 /* _sourceChainId */,
        bytes32[] calldata /* _intentHashes */,
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
