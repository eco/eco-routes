// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LocalPolicy} from "../prover/LocalPolicy.sol";

/**
 * @title LocalPolicyTron
 * @notice LocalPolicy variant for Tron chains.
 * @dev In v3 the reward payout flows through the Vault (Tron non-standard-ERC20 handling lives in
 *      {VaultTron}), so LocalPolicy no longer transfers reward tokens itself and needs no Tron-specific
 *      transfer override. This subclass is retained as the Tron deployment target.
 */
contract LocalPolicyTron is LocalPolicy {
    constructor(address portal) LocalPolicy(portal) {}
}
