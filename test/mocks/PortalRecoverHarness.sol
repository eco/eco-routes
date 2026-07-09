// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Portal} from "../../contracts/Portal.sol";
import {IVault} from "../../contracts/interfaces/IVault.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {Reward} from "../../contracts/types/Intent.sol";

/**
 * @title PortalRecoverHarness
 * @notice A Portal that additionally exposes {recoverTokenUnsafe} — the PRE-FIX body of
 *         {IntentSource-recoverToken}, i.e. production `recoverToken` with ONLY the native-alias
 *         branch of `_validateRecover` removed.
 *
 * @dev Kept alongside the fixed portal so a single test can show the drain is OPEN before the fix
 *      and CLOSED after it (see NativeErc20Dual.t.sol). The delta between this and a stock
 *      {Portal} is therefore EXACTLY the fix — nothing more. Production `_validateRecover` is:
 *
 *          if (token == address(0)) revert InvalidRecoverToken(token);          // kept below
 *          for (i..) if (reward.tokens[i].token == token) revert ...;           // kept below
 *          if (token == NATIVE_ERC20 && reward.nativeAmount != 0) revert ...;    // THE FIX — omitted
 *
 *      So this harness reproduces recoverToken as it behaved BEFORE the fix for any input: the
 *      zero-address and reward-token checks still run; only the same-underlying-balance (native
 *      alias) check is absent.
 *
 *      With a {MockDualInterfaceToken} as the configured native alias, `vault.recover` moves the
 *      vault's native balance out through the ERC20 interface — draining a native reward that a
 *      solver is owed back to the intent creator. The production guard reverts before reaching
 *      `vault.recover`; this harness lets a test observe the loss the fix prevents.
 */
contract PortalRecoverHarness is Portal {
    constructor(address nativeErc20) Portal(nativeErc20) {}

    /// @notice Pre-fix {IntentSource-recoverToken}: the eligibility checks that existed before the
    ///         fix run, but NOT the native-alias branch the fix added.
    function recoverTokenUnsafe(
        uint64 destination,
        bytes32 routeHash,
        Reward calldata reward,
        address token
    ) external {
        (bytes32 intentHash, , ) = getIntentHash(
            destination,
            routeHash,
            reward
        );

        // Pre-fix _validateRecover: everything except the native-alias branch (the fix).
        if (token == address(0)) {
            revert IIntentSource.InvalidRecoverToken(token);
        }
        uint256 rewardsLength = reward.tokens.length;
        for (uint256 i; i < rewardsLength; ++i) {
            if (reward.tokens[i].token == token) {
                revert IIntentSource.InvalidRecoverToken(token);
            }
        }
        // Production adds here: `if (token == NATIVE_ERC20 && reward.nativeAmount != 0) revert;`

        IVault vault = IVault(_getOrDeployVault(intentHash));
        vault.recover(reward.creator, token);
    }
}
