/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "./Clones.sol";

/**
 * @title AccountDeployer
 * @notice Shared, ROLE-AWARE per-intent {Account} address derivation + deployment for the two Portal
 *         halves (Model C — chain-parameterized dual account).
 * @dev A per-intent Account is an ERC-1167 minimal-proxy clone deployed via CREATE2. In Model C the
 *      CREATE2 salt is parameterized by a ROLE chain id on top of the intent hash:
 *
 *        accountSalt = keccak256(abi.encode(intentHash, roleChainId))
 *
 *        - source / escrow account:   roleChainId == intent.source
 *        - destination / execution:   roleChainId == intent.destination
 *
 *      When `source == destination` (a same-chain intent) the two salts are IDENTICAL, so the escrow
 *      and the execution collapse to ONE Account at ONE address. When they differ (a cross-chain intent)
 *      they are two distinct addresses on two chains: the source-side reward escrow lives at
 *      `keccak(intentHash, source)` and any destination execution leftover lives at
 *      `keccak(intentHash, destination)`. This ADDRESS SEPARATION is the core Model C safety property —
 *      source-side operations (fund/settle/refund/recover/executeAsOwner) only ever touch the SOURCE
 *      account, so an A->B intent's destination account can never be reached by a source-side op (the
 *      account-confusion attack dissolves by construction).
 *
 *      Both Portal halves inherit this base so they resolve byte-identical addresses; because the proxy
 *      creation code is constant and the Portal has the same address on every chain, a given
 *      `(intentHash, roleChainId)` maps to the same address on every chain. The concrete {Portal}
 *      supplies the constructor args once via C3 linearization (`AccountDeployer` appears a single time in
 *      the linearization even though both halves inherit it).
 */
abstract contract AccountDeployer {
    using Clones for address;

    /// @notice CREATE2 prefix for deterministic Account addressing (0xff on EVM, 0x41 on TRON).
    bytes1 internal immutable CREATE2_PREFIX;

    /// @notice {Account} implementation cloned per intent (the shared delegate target for every clone).
    address internal immutable ACCOUNT_IMPLEMENTATION;

    /**
     * @notice Wires the Account clone template and CREATE2 prefix.
     * @param accountImplementation Address of the {Account} implementation; per-intent clones delegate to it.
     * @param create2Prefix CREATE2 prefix byte (0xff for standard EVM chains, 0x41 for TRON).
     */
    constructor(address accountImplementation, bytes1 create2Prefix) {
        ACCOUNT_IMPLEMENTATION = accountImplementation;
        CREATE2_PREFIX = create2Prefix;
    }

    /**
     * @notice The chain-parameterized CREATE2 salt for an Account (Model C).
     * @param intentHash The hash of the intent.
     * @param roleChainId The role chain id (`intent.source` for escrow, `intent.destination` for
     *        execution).
     * @return The CREATE2 salt.
     */
    function _accountSalt(
        bytes32 intentHash,
        uint64 roleChainId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(intentHash, roleChainId));
    }

    /**
     * @notice Computes the deterministic per-intent Account address for an intent hash and role chain id.
     * @param intentHash The hash of the intent.
     * @param roleChainId `intent.source` (escrow) or `intent.destination` (execution).
     * @return The predicted (or deployed) Account address.
     */
    function accountAddress(
        bytes32 intentHash,
        uint64 roleChainId
    ) public view returns (address) {
        return
            ACCOUNT_IMPLEMENTATION.predict(
                _accountSalt(intentHash, roleChainId),
                CREATE2_PREFIX
            );
    }

    /**
     * @notice Returns the per-intent Account for a role, deploying its clone via CREATE2 if it does not
     *         yet exist.
     * @dev Idempotent: funds may arrive at the deterministic address before the clone exists (the
     *      address is computed first, deployed lazily), so callers always derive then deploy-if-needed.
     * @param intentHash The hash of the intent.
     * @param roleChainId `intent.source` (escrow) or `intent.destination` (execution).
     * @return account The Account address (now guaranteed to have code).
     */
    function _getOrDeployAccount(
        bytes32 intentHash,
        uint64 roleChainId
    ) internal returns (address account) {
        bytes32 salt = _accountSalt(intentHash, roleChainId);
        account = ACCOUNT_IMPLEMENTATION.predict(salt, CREATE2_PREFIX);
        if (account.code.length == 0) {
            ACCOUNT_IMPLEMENTATION.clone(salt);
        }
    }
}
