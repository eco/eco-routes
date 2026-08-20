// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title MockDomainProver
 * @notice Minimal stand-in exposing only `chainIdByDomain`
 * @dev Used to test aggregator member validation without deploying a full
 *      MessageBridgeProver and its bridge dependencies.
 */
contract MockDomainProver {
    mapping(uint64 => uint64) private _chainIdByDomain;

    function setDomain(uint64 domain, uint64 chainId) external {
        _chainIdByDomain[domain] = chainId;
    }

    function chainIdByDomain(uint64 domain) external view returns (uint64) {
        return _chainIdByDomain[domain];
    }
}
