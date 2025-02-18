/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IVaultStorage
 * @notice Interface for the storage layout of the Vault contract
 */
interface IVaultStorage {
    enum RewardStatus {
        Initial,
        PartiallyFunded,
        Funded,
        Claimed,
        Refunded
    }

    /**
     * @notice Mode of the vault contract
     */
    enum VaultMode {
        Fund,
        Claim,
        Refund,
        RecoverToken
    }

    /**
     * @notice Status of the vault contract
     * @dev Tracks the current mode and funding status
     * @param status Current status of the vault
     * @param mode Current mode of the vault
     * @param allowPartial Whether partial funding is allowed
     * @param isPermit2 Whether permit2 is enabled
     * @param target Address of the funder in Fund, claimant in Claim or refund token in RefundToken mode
     */
    struct VaultState {
        uint8 status; // RewardStatus
        uint8 mode; // VaultMode
        uint8 allowPartialFunding; // boolean
        uint8 isPermit2; // boolean
        address target; // funder, claimant or refund token address
    }

    /**
     * @notice Storage for the vault contract
     * @dev Tracks the current state and permit2 instance
     * @param state Current state of the vault
     * @param permit2 Address of the permit2 instance
     */
    struct VaultStorage {
        VaultState state; // 1 bytes32 storage slot
        address permit2; // permit2 instance
    }
}
