// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProver} from "../interfaces/IProver.sol";

/**
 * @title MockDomainProverDirtyChainId
 * @notice Stand-in whose `chainIdByDomain` returns a full 32-byte word with
 *         non-zero upper bits instead of a clean `uint64`
 * @dev Pins the strict-decode trap in Deploy._tryChainIdByDomain. The probe
 *      returns a 32-byte payload, so a `success`/`ret.length == 32` check
 *      passes it through — but `abi.decode(ret, (uint64))` is strict and would
 *      revert in the PROBE'S OWN frame, uncatchably, aborting the entire deploy
 *      with a bare decode revert instead of surfacing the intended
 *      "member does not expose chainIdByDomain" require. The probe must decode
 *      wide and range-check instead.
 *
 *      This matters most for third-party members admitted via
 *      AGGREGATOR_PROVER_ALLOW_UNVERIFIED_MEMBERS — the only members whose
 *      return shape the deployer does not control.
 */
contract MockDomainProverDirtyChainId {
    /// @dev Declared as returning uint256 so solc emits a full dirty word.
    function chainIdByDomain(uint64) external pure returns (uint256) {
        return type(uint256).max;
    }

    function provenIntents(
        bytes32
    ) external pure returns (IProver.ProofData memory) {
        return IProver.ProofData({claimant: address(0), destination: 0});
    }
}
