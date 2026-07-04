/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IAccount} from "../interfaces/IAccount.sol";
import {IPermit} from "../interfaces/IPermit.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {Reward, RewardToken} from "../types/Intent.sol";

/**
 * @title Account
 * @notice Escrow + execution contract for cross-chain rewards (v3 rate+flat legs) and route runtimes.
 * @dev Implements a lifecycle-based account that can be funded, withdrawn from, or refunded. Rewards are
 *      per-token legs; native folds in as a leg with `token == address(0)`. On withdraw the Account
 *      consults `reward.prover` (as a VIEW — no reentrancy surface) to turn the core-verified
 *      `fulfilled[]` into per-leg amounts, pays each capped at its own balance to the claimant, and
 *      sweeps the residual to the keeper.
 *
 *      On the DESTINATION side the same Account also EXECUTES the route: the Inbox stages the solver's
 *      input onto this Account and calls {execute}, which `delegatecall`s the committed `route.runtime`
 *      so the runtime spends the Account's own balance. Any unconsumed input simply stays here for the
 *      keeper to retrieve later (unopinionated core — no auto-sweep).
 */
contract Account is IAccount {
    /// @notice Address of the portal contract that can call this account
    address private immutable portal;

    using SafeERC20 for IERC20;
    using Math for uint256;

    /**
     * @notice In-execute slot: holds the runtime ADDRESS while {execute} is on the stack, else 0.
     * @dev A nonzero value doubles as the in-progress flag: the gated {fallback} forwards in-flight
     *      callbacks only when the slot is nonzero (and to that runtime) and reverts
     *      {FallbackNotInExecute} otherwise, closing the unauthenticated-delegatecall drain vector.
     *      Stored at an explicit HIGH hashed slot (== keccak256("eco.routes.v3.account.inExecute"),
     *      inlined as a numeric literal because inline assembly cannot reference a keccak expression) so
     *      it never collides with the LOW slots a delegatecalled runtime may write in this Account's
     *      context. Paris EVM has no transient storage, so this is a regular storage slot; it is set at
     *      the start of {execute} and cleared at the end (on revert the whole frame — and this write —
     *      rolls back), so it is only ever observed nonzero mid-{execute}.
     */
    bytes32 private constant _IN_EXECUTE_SLOT =
        0xacc20dacae6b4d5949ef091bdce937ee4ae97c3312ea3d3826cb7ff678dcaca3;

    /**
     * @notice Creates a new account instance
     * @dev Sets the deployer (IntentSource) as the authorized portal contract
     */
    constructor() {
        portal = msg.sender;
    }

    /**
     * @notice Restricts function access to only the portal contract
     */
    modifier onlyPortal() {
        if (msg.sender != portal) {
            revert NotPortalCaller(msg.sender);
        }

        _;
    }

    /**
     * @notice Funds the account with reward legs from the funder
     * @dev `targets[j]` is the escrow target for reward leg `j` (computed by IntentSource from the paired
     *      `minTokens` and the leg's rate/flat). Native (`token == address(0)`) is funded from `msg.value`;
     *      ERC20 legs are pulled via permit then standing allowance.
     * @param reward The reward structure containing the legs
     * @param targets Per-leg escrow targets, index-aligned with `reward.tokens`
     * @param funder Address that will provide the funding
     * @param permit Optional permit contract for gasless token approvals
     * @return fullyFunded True if every leg reached its target, false otherwise
     */
    function fundFor(
        Reward calldata reward,
        uint256[] calldata targets,
        address funder,
        IPermit permit
    ) external payable onlyPortal returns (bool fullyFunded) {
        fullyFunded = true;

        uint256 rewardsLength = reward.tokens.length;
        for (uint256 i; i < rewardsLength; ++i) {
            address tokenAddr = reward.tokens[i].token;
            uint256 target = targets[i];

            if (tokenAddr == address(0)) {
                // Native leg: funded from the value already delivered to the account.
                fullyFunded = fullyFunded && address(this).balance >= target;
                continue;
            }

            IERC20 token = IERC20(tokenAddr);
            uint256 remaining = _fundFromPermit(funder, token, target, permit);
            remaining = _fundFrom(funder, token, remaining);

            fullyFunded = fullyFunded && remaining == 0;
        }
    }

    /**
     * @notice Withdraws the owed reward to the claimant and sweeps the residual to the keeper
     * @dev Consults `reward.prover.previewRelease(reward, fulfilled)` (a VIEW) for the per-leg amounts,
     *      pays each capped at its own balance to `claimant`, and returns the leftover of each leg token
     *      to `reward.keeper`.
     * @param reward The reward structure defining the legs and the prover
     * @param claimant Address that will receive the owed reward
     * @param fulfilled Core-verified per-leg delivered amounts (paired prefix)
     */
    function withdraw(
        Reward calldata reward,
        address claimant,
        uint256[] calldata fulfilled
    ) external onlyPortal {
        uint256[] memory payNow = IPolicy(reward.prover).previewRelease(
            reward,
            fulfilled
        );

        uint256 rewardsLength = reward.tokens.length;
        for (uint256 i; i < rewardsLength; ++i) {
            address tokenAddr = reward.tokens[i].token;

            if (tokenAddr == address(0)) {
                uint256 pay = payNow[i].min(address(this).balance);
                if (pay > 0) {
                    // Try to send to claimant - if it fails, ETH remains for the keeper sweep below
                    claimant.call{value: pay}("");
                }
                uint256 residual = address(this).balance;
                if (residual > 0) {
                    reward.keeper.call{value: residual}("");
                }
                continue;
            }

            IERC20 token = IERC20(tokenAddr);
            uint256 balance = token.balanceOf(address(this));
            uint256 payAmount = payNow[i].min(balance);
            if (payAmount > 0) {
                _transferToken(token, claimant, payAmount);
            }
            uint256 tokenResidual = token.balanceOf(address(this));
            if (tokenResidual > 0) {
                _transferToken(token, reward.keeper, tokenResidual);
            }
        }
    }

    /**
     * @notice Refunds all account contents to a specified address
     * @param reward The reward structure containing the leg tokens
     * @param refundee Address to receive the refunded rewards
     */
    function refund(
        Reward calldata reward,
        address refundee
    ) external onlyPortal {
        uint256 rewardsLength = reward.tokens.length;
        for (uint256 i; i < rewardsLength; ++i) {
            address tokenAddr = reward.tokens[i].token;
            if (tokenAddr == address(0)) {
                continue;
            }
            IERC20 token = IERC20(tokenAddr);
            uint256 amount = token.balanceOf(address(this));

            if (amount > 0) {
                _transferToken(token, refundee, amount);
            }
        }

        uint256 nativeAmount = address(this).balance;
        if (nativeAmount > 0) {
            // Try to send to refundee - if it fails, ETH remains in account for future refund attempts
            refundee.call{value: nativeAmount}("");
        }
    }

    /**
     * @notice Recovers tokens that are not part of the reward to the keeper
     * @param refundee Address to receive the recovered tokens
     * @param token Address of the token to recover (must not be a reward token)
     */
    function recover(address refundee, address token) external onlyPortal {
        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));

        if (balance == 0) {
            revert ZeroRecoverTokenBalance(token);
        }

        _transferToken(tokenContract, refundee, balance);
    }

    /**
     * @notice Runs a runtime against this Account's own funds via `delegatecall`.
     * @dev `onlyPortal`. The Portal stages the route inputs (ERC20 legs + forwarded native) onto this
     *      Account, then calls this to execute the keeper-committed `Route.runtime(payload)`. Because the
     *      runtime is reached by `delegatecall`, it runs in THIS Account's context — `address(this)`,
     *      balances and approvals are the Account's — so it spends the staged inputs directly. The raw
     *      return/revert data is bubbled verbatim (failures are never swallowed); declared
     *      `returns (bytes memory)` to satisfy the ABI, but control never falls through to a Solidity
     *      return because every assembly path terminates in `return`/`revert`.
     *
     *      Stores `runtime` in {_IN_EXECUTE_SLOT} (a nonzero address == in-execute) for the duration of
     *      the delegatecall so legitimate in-flight callbacks (e.g. a DEX pool callback) re-entering
     *      this Account's address land in {fallback} and are forwarded to that SAME runtime. The slot is
     *      cleared on the success path; on the revert path the whole frame (and the slot write) rolls
     *      back — the slot is never observed nonzero after `execute` returns.
     *
     *      RETURN ENCODING: on failure the raw revert data is bubbled VERBATIM (`revert(...)`), so a
     *      runtime revert reason propagates unchanged. On success the raw runtime return data is wrapped
     *      as a canonical ABI `bytes` (`[offset=0x20][len][data]`) so the typed caller
     *      (`IAccount.execute returns (bytes memory)`) decodes it — a runtime that returns 0 bytes (e.g.
     *      the {MulticallRuntime} fallback) would otherwise make the caller's `bytes` decode revert.
     * @param runtime The delegatecall target (committed in the route hash).
     * @param payload The opaque program forwarded to `runtime` verbatim.
     * @return The runtime's raw return data (ABI-wrapped as `bytes`).
     */
    function execute(
        address runtime,
        bytes calldata payload
    ) external payable onlyPortal returns (bytes memory) {
        assembly ("memory-safe") {
            // Mark `execute` in progress by storing the runtime address (nonzero) so {fallback}
            // forwards legitimate in-flight callbacks to it.
            sstore(_IN_EXECUTE_SLOT, runtime)
            let ptr := mload(0x40)
            calldatacopy(ptr, payload.offset, payload.length)
            let ok := delegatecall(gas(), runtime, ptr, payload.length, 0, 0)
            switch ok
            // On failure bubble the raw revert data verbatim, rolling back the slot write above.
            case 0 {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            // On success, clear the slot and return the raw return data wrapped as ABI `bytes`.
            default {
                sstore(_IN_EXECUTE_SLOT, 0)
                let len := returndatasize()
                let out := mload(0x40)
                mstore(out, 0x20)
                mstore(add(out, 0x20), len)
                returndatacopy(add(out, 0x40), 0, len)
                return(out, add(0x40, len))
            }
        }
    }

    /**
     * @notice Accepts plain native transfers (counterfactual escrow funding, WETH unwraps, native swap
     *         proceeds). Carries no calldata, so it never reaches the gated {fallback}.
     */
    receive() external payable {}

    /**
     * @notice Gated forwarder for runtime self-calls and swap callbacks during {execute}.
     * @dev Forwards ONLY while a Portal-driven {execute} is on the stack — i.e. while {_IN_EXECUTE_SLOT}
     *      holds a nonzero runtime address, which is also the runtime to forward to (the callback is
     *      delegated to it with the raw calldata and `msg.sender` preserved, bubbling its return/revert).
     *      Outside {execute} the slot is zero and this path reverts {FallbackNotInExecute}, closing the
     *      unauthenticated-delegatecall drain vector: without the gate the default {MulticallRuntime}
     *      would interpret attacker calldata as `abi.encode(Call[])` and move funds stranded at this
     *      address, bypassing the Portal-gated rescue paths. `receive()` stays open for plain native.
     */
    fallback() external payable {
        address runtime = _loadInExecuteRuntime();
        if (runtime == address(0)) {
            revert FallbackNotInExecute(msg.sender);
        }
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let ok := delegatecall(gas(), runtime, ptr, calldatasize(), 0, 0)
            returndatacopy(ptr, 0, returndatasize())
            switch ok
            case 0 {
                revert(ptr, returndatasize())
            }
            default {
                return(ptr, returndatasize())
            }
        }
    }

    /**
     * @dev Reads the in-execute runtime address from {_IN_EXECUTE_SLOT} (nonzero while {execute} runs,
     *      else address(0)).
     */
    function _loadInExecuteRuntime() private view returns (address runtime) {
        assembly ("memory-safe") {
            runtime := sload(_IN_EXECUTE_SLOT)
        }
    }

    /**
     * @notice Internal function to fund account with tokens using standard ERC20 transfers
     * @param funder Address providing the tokens
     * @param token ERC20 token contract
     * @param remainingAmount Remaining amount needed to fully fund the leg
     * @return uint256 Remaining amount needed to fully fund the leg
     */
    function _fundFrom(
        address funder,
        IERC20 token,
        uint256 remainingAmount
    ) internal returns (uint256) {
        if (remainingAmount == 0) {
            return 0;
        }

        uint256 allowance = token.allowance(funder, address(this));
        uint256 funderBalance = token.balanceOf(funder);

        uint256 transferAmount = remainingAmount.min(funderBalance).min(
            allowance
        );

        if (transferAmount > 0) {
            token.safeTransferFrom(funder, address(this), transferAmount);
        }

        return remainingAmount - transferAmount;
    }

    /**
     * @notice Internal function to fund account using permit-based transfers
     * @param funder Address providing the tokens
     * @param token ERC20 token contract
     * @param rewardAmount Required token amount for the leg
     * @param permit Permit contract for gasless approvals
     * @return uint256 Remaining amount needed to fully fund the leg
     */
    function _fundFromPermit(
        address funder,
        IERC20 token,
        uint256 rewardAmount,
        IPermit permit
    ) internal returns (uint256) {
        uint256 balance = token.balanceOf(address(this));

        if (balance >= rewardAmount) {
            return 0;
        }

        if (address(permit) == address(0)) {
            return rewardAmount - balance;
        }

        (uint160 allowance, , ) = permit.allowance(
            funder,
            address(token),
            address(this)
        );
        uint256 funderBalance = token.balanceOf(funder);

        uint256 transferAmount = (rewardAmount - balance)
            .min(funderBalance)
            .min(uint256(allowance));

        if (transferAmount > 0) {
            permit.transferFrom(
                funder,
                address(this),
                uint160(transferAmount),
                address(token)
            );
        }

        return rewardAmount - token.balanceOf(address(this));
    }

    /**
     * @notice Transfers ERC20 tokens out of the account.
     * @dev Virtual so subclasses can override for non-standard tokens (e.g. Tron USDT).
     * @param token ERC20 token to transfer
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _transferToken(
        IERC20 token,
        address to,
        uint256 amount
    ) internal virtual {
        token.safeTransfer(to, amount);
    }
}
