// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MessageBridgePolicy} from "../prover/MessageBridgePolicy.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {IMessageBridgePolicy} from "../interfaces/IMessageBridgePolicy.sol";

/**
 * @title TestMessagePolicy
 * @notice Test implementation of MessageBridgePolicy for unit testing
 * @dev Focuses on testing the MessageBridgePolicy interface and whitelist functionality
 */
contract TestMessagePolicy is MessageBridgePolicy {
    // Track dispatch state for testing
    bool public dispatched = false;
    uint256 public dispatchCallCount = 0;

    // Fee configuration for testing
    uint256 public feeAmount = 100000;

    // No events needed for testing

    constructor(
        address _portal,
        bytes32[] memory _provers,
        uint256 _gasLimit
    ) MessageBridgePolicy(_portal, _provers, _gasLimit) {}

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
     * @notice Test entrypoint that processes a raw cross-chain message
     * @dev The prove signature is now the dispatch direction (it builds the wire message from the
     *      prover's own store). Reception processing is unchanged; this shim lets tests feed a raw
     *      chain-id-prefixed message straight into {_handleCrossChainMessage}.
     */
    function receiveProofs(
        address _sender,
        bytes calldata _encodedProofs
    ) external {
        // Basic validation - the message includes 8 bytes chain ID + proof pairs
        if (_encodedProofs.length < 8) {
            revert IMessageBridgePolicy.InvalidProofMessage();
        }
        if ((_encodedProofs.length - 8) % 64 != 0) {
            revert IPolicy.ArrayLengthMismatch();
        }

        // Process the intent proofs using the base implementation
        _handleCrossChainMessage(
            bytes32(uint256(uint160(_sender))),
            _encodedProofs
        );

        // For testing, we don't actually dispatch, just mark it
        dispatched = true;
        dispatchCallCount++;
    }

    /**
     * @notice Mock implementation of fetchFee
     * @dev Returns a fixed fee amount for testing
     */
    function fetchFee(
        uint64 /* domainID */,
        bytes memory /* _encodedProofs */,
        bytes calldata /* _data */
    ) public view override returns (uint256) {
        return feeAmount;
    }

    /**
     * @notice Mock implementation of _dispatchMessage
     * @dev Just tracks that dispatch was called
     */
    function _dispatchMessage(
        uint64 /* domainID */,
        bytes memory /* encodedProofs */,
        bytes calldata /* data */,
        uint256 /* fee */
    ) internal override {
        dispatched = true;
        dispatchCallCount++;
    }

    /**
     * @notice Helper to manually add a proven intent (hash-only fact) for testing
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

    /**
     * @notice Helper to set fee amount for testing
     */
    function setFeeAmount(uint256 _feeAmount) public {
        feeAmount = _feeAmount;
    }

    /**
     * @notice Helper to reset dispatch state for testing
     */
    function resetDispatchState() public {
        dispatched = false;
        dispatchCallCount = 0;
    }

    /**
     * @notice Implementation of getProofType from IPolicy
     * @return String indicating the proving mechanism used
     */
    function getProofType() external pure override returns (string memory) {
        return "TestMessagePolicy";
    }

    function version() external pure returns (string memory) {
        return "test";
    }
}
