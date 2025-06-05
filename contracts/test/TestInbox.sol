// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title TestInbox
 * @notice A simplified test version of Inbox that allows manual setting of fulfilled mapping
 * @dev Used for testing SameChainProver without complex fulfillment logic
 */
contract TestInbox {
    /**
     * @notice Mapping of intent hashes to their claimant addresses
     * @dev Public to match the real Inbox interface
     */
    mapping(bytes32 => address) public fulfilled;

    /**
     * @notice Manually set a fulfilled intent for testing
     * @param _intentHash Hash of the intent
     * @param _claimant Address of the claimant
     */
    function setFulfilled(bytes32 _intentHash, address _claimant) external {
        fulfilled[_intentHash] = _claimant;
    }

    /**
     * @notice Clear a fulfilled intent for testing
     * @param _intentHash Hash of the intent to clear
     */
    function clearFulfilled(bytes32 _intentHash) external {
        fulfilled[_intentHash] = address(0);
    }

    /**
     * @notice Check if an intent is fulfilled
     * @param _intentHash Hash of the intent
     * @return Boolean indicating if intent is fulfilled
     */
    function isFulfilled(bytes32 _intentHash) external view returns (bool) {
        return fulfilled[_intentHash] != address(0);
    }
}