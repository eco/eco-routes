// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title MockDomainProverLegacyShape
 * @notice Stand-in exposing `chainIdByDomain` and the pre-cancellation
 *         two-word provenIntents return (address claimant, uint64 destination)
 * @dev Used to test that Deploy.validateAggregatorProverMembers rejects
 *      members that AggregatorProver would skip forever.
 */
contract MockDomainProverLegacyShape {
    function chainIdByDomain(uint64) external pure returns (uint64) {
        return 0;
    }

    function provenIntents(bytes32) external pure returns (address, uint64) {
        return (address(0), 0);
    }
}
