/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVaultStorage} from "./IVaultStorage.sol";

/**
 * @title IVault
 * @notice Interface defining errors for the Vault.sol contract
 */
interface IVault is IVaultStorage {
    /**
     * @notice Thrown when the vault has insufficient token allowance for reward funding
     */
    error InsufficientTokenAllowance(
        address token,
        address spender,
        uint256 amount
    );

    /**
     * @notice Thrown when the vault is not able to properly reward the claimant
     * @dev For edge cases where the reward balance is not sufficient etc
     */
    event RewardTransferFailed(
        address indexed token,
        address indexed to,
        uint256 amount
    );
}
