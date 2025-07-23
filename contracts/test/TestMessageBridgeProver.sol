// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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
    bytes32[] public lastClaimants;
    bytes32 public lastSourceChainProver;
    bytes public lastData;

    uint256 public feeAmount = 100000;

    // No events needed for testing

    constructor(
        address _portal,
        bytes32[] memory _provers,
        uint256 _gasLimit
    ) MessageBridgeProver(_portal, _provers, _gasLimit) {}

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
        return isWhitelisted(bytes32(uint256(uint160(_prover))));
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
        bytes32[] memory whitelistBytes32 = getWhitelist();
        address[] memory whitelistAddresses = new address[](
            whitelistBytes32.length
        );

        for (uint256 i = 0; i < whitelistBytes32.length; i++) {
            whitelistAddresses[i] = address(bytes20(whitelistBytes32[i]));
        }

        return whitelistAddresses;
    }

    // No custom events needed for testing

    /**
     * @notice Mock implementation of prove
     * @dev Records arguments and marks dispatched = true
     */
    function prove(
        address /* _sender */,
        uint256 _sourceChainId,
        bytes calldata _encodedProofs,
        bytes calldata _data
    ) external payable override {
        // Extract intentHashes and claimants from encodedProofs
        (
            bytes32[] memory intentHashes,
            bytes32[] memory claimants
        ) = _extractFromEncodedProofs(_encodedProofs);

        dispatched = true;
        lastSourceChainId = _sourceChainId;

        // Store arrays for later verification
        delete lastIntentHashes;
        delete lastClaimants;

        for (uint256 i = 0; i < intentHashes.length; i++) {
            lastIntentHashes.push(intentHashes[i]);
        }

        for (uint256 i = 0; i < claimants.length; i++) {
            lastClaimants.push(claimants[i]);
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
        bytes calldata /* _encodedProofs */,
        bytes calldata /* _data */
    ) public view override returns (uint256) {
        return feeAmount;
    }

    /**
     * @notice Mock implementation of _dispatchMessage
     * @dev Does nothing for testing purposes
     */
    function _dispatchMessage(
        uint256 /* sourceChainId */,
        bytes calldata /* encodedProofs */,
        bytes calldata /* data */,
        uint256 /* fee */
    ) internal pure override {
        // solhint-disable-previous-line no-unused-vars
        // Mock implementation - does nothing
        return;
    }

    /**
     * @notice Helper method to manually add proven intents for testing
     * @param _hash Intent hash
     * @param _claimant Claimant address
     * @param _destination Destination chain ID
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
