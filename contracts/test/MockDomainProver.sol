// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProver} from "../interfaces/IProver.sol";

/**
 * @title MockDomainProver
 * @notice Minimal stand-in exposing `chainIdByDomain` and a well-formed
 *         `provenIntents`
 * @dev Used to test aggregator member validation without deploying a full
 *      MessageBridgeProver and its bridge dependencies. `provenIntents`
 *      always returns a zero ProofData so the shape probe in
 *      Deploy.validateEcoProverMembers passes for an honest member.
 */
contract MockDomainProver {
    mapping(uint64 => uint64) private _chainIdByDomain;

    function setDomain(uint64 domain, uint64 chainId) external {
        _chainIdByDomain[domain] = chainId;
    }

    function chainIdByDomain(uint64 domain) external view returns (uint64) {
        return _chainIdByDomain[domain];
    }

    function provenIntents(
        bytes32
    ) external pure returns (IProver.ProofData memory) {
        return IProver.ProofData({claimant: address(0), destination: 0});
    }
}
