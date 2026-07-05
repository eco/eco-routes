/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {OriginSettler} from "./OriginSettler.sol";
import {DestinationSettler} from "./DestinationSettler.sol";

import {IInbox} from "../interfaces/IInbox.sol";
import {IPortalProxy} from "../interfaces/IPortalProxy.sol";

import {Route, Reward} from "../types/Intent.sol";

/**
 * @title IPortalPublishAndFund
 * @notice The two decomposed source-side entry points the ERC-7683 adapter delegatecalls into the resolved
 *         Portal implementation. Declared as a dedicated, NON-overloaded interface purely so
 *         {abi.encodeCall} can reference each unambiguously — the public {IIntentSource} counterparts are
 *         overloaded (a struct form + this decomposed form), and `abi.encodeCall`/`.selector` cannot pick
 *         between overloads by name. The signatures (hence selectors) are byte-identical to
 *         {IIntentSource.publishAndFund}/{IIntentSource.publishAndFundFor}'s decomposed overloads.
 */
interface IPortalPublishAndFund {
    function publishAndFund(
        uint32 protocolVersion,
        uint64 source,
        uint64 destination,
        bytes memory route,
        Reward memory reward,
        bool allowPartial
    ) external payable returns (bytes32 intentHash, address account);

    function publishAndFundFor(
        uint32 protocolVersion,
        uint64 source,
        uint64 destination,
        bytes memory route,
        Reward memory reward,
        bool allowPartial,
        address funder,
        address permitContract
    ) external payable returns (bytes32 intentHash, address account);
}

/**
 * @title ERC7683Implementation
 * @notice The Eco Protocol's ERC-7683 adapter, split OUT of the core Portal implementation so the Portal
 *         reclaims the Settlers' bytecode (the ERC-7683 surface is lower-priority and can pay one extra
 *         delegatecall hop).
 * @dev Inherits ONLY the two ERC-7683 Settlers — NOT {IntentSource}, {Inbox}, {AccountDeployer} or
 *      {Semver}. It duplicates NONE of the core intent logic. Its two abstract Settler hooks
 *      ({OriginSettler-_publishAndFund}, {DestinationSettler-fulfillAndProve}) resolve the pinned Portal
 *      implementation for the call's `protocolVersion` and `delegatecall` DIRECTLY into its real
 *      `publishAndFund(For)` / `fulfillAndProve`.
 *
 *      EXECUTION CONTEXT. This contract is reached only via {PortalCore-fallback} — itself only reached via
 *      `delegatecall` from the {PortalProxy}. So every call runs TWO delegatecalls deep in the proxy's
 *      context: `address(this)` is the PROXY and `msg.sender` is the ORIGINAL caller. The final
 *      `delegatecall` into the resolved Portal implementation is a THIRD hop that, being a delegatecall,
 *      again preserves BOTH — which is the whole point:
 *        - the Portal implementation reads/writes the proxy's storage (one consistent `rewardStatuses`
 *          view, computed by the Portal's own bytecode — this adapter never touches it), and
 *        - `msg.sender` is preserved. This matters CRITICALLY for the fulfill path: {Inbox._fulfill} pulls
 *          the solver's ERC20 input with `safeTransferFrom(msg.sender, account, provided)` — HARDCODED to
 *          `msg.sender`, no explicit-provider parameter. A plain external self-CALL back through the proxy
 *          would reset `msg.sender` to the proxy (which holds no solver funds) and silently break every
 *          `fill()`. A `delegatecall` never rebases `msg.sender`, so the solver's own tokens are pulled.
 *
 *      STORAGE. This contract declares no storage of its own; its only inherited storage is OZ {EIP712}'s
 *      two fallback-string slots (unused at runtime for the short "EcoPortal"/"1" name, which live as
 *      immutables in code). It never reads/writes `rewardStatuses` directly — that always happens inside
 *      the delegatecalled Portal bytecode — so there is no cross-contract slot-alignment requirement with
 *      the lean Portal (the failure mode of the earlier fat design).
 */
contract ERC7683Implementation is OriginSettler, DestinationSettler {
    /**
     * @notice Initializes the EIP-712 domain used by {OriginSettler}'s gasless-order signature check.
     * @dev Required here because this contract no longer inherits {IntentSource} (which owns the EIP712
     *      constructor call in the lean Portal). {OriginSettler} always inherits {EIP712}, so the 2-slot
     *      layout is contributed identically regardless — and since both this contract and the lean Portal
     *      are only ever reached via `delegatecall` against the PROXY, neither's constructor-time EIP712
     *      writes are ever read at runtime: every call takes EIP712's `address(this) != cachedThis` rebuild
     *      branch, which reconstructs the domain separator from the immutable (code) hashed name/version,
     *      yielding an identical, correct separator. Same situation the lean Portal is already in (PR9);
     *      just reached via a different base.
     */
    constructor() EIP712("EcoPortal", "1") {}

    /**
     * @notice {OriginSettler} hook: create + fund an intent by delegatecalling the resolved Portal
     *         implementation's real `publishAndFund(For)`.
     * @dev Resolves the implementation for `protocolVersion` (a harmless VIEW self-read of the proxy's
     *      registry) then `delegatecall`s it, preserving `address(this)`=proxy and `msg.sender`. Chooses the
     *      target to PRESERVE the funder-allowance semantics of the pre-split ERC-7683 path:
     *        - `funder == msg.sender` (the {open} case, or a self-relayed {openFor}): route to the
     *          `msg.sender` overload `publishAndFund`, which pulls each ERC20 leg via the PROXY's allowance
     *          (`safeTransferFrom(funder, account)` executed by the Portal) — byte-for-byte the legacy
     *          `open()` behaviour, so proxy approvals keep working unchanged.
     *        - `funder != msg.sender` (a gasless {openFor} whose signed user is not the relayer): route to
     *          `publishAndFundFor` with an empty permit. There is NO safe public way to pull from an
     *          ARBITRARY funder via the proxy's allowance (that would let anyone drain any proxy approver),
     *          so this path necessarily uses the per-intent Account's allowance instead — the signed user
     *          must approve the (deterministic, pre-computable) intent Account. This is the one unavoidable
     *          funder-allowance change introduced by the lean split, and only for cross-relayer openFor.
     * @param protocolVersion Creator-declared Portal implementation version (selects the delegatecall target)
     * @param source Origin chain ID (block.chainid at open time) committed in the intent hash
     * @param destination Destination chain ID where the intent should be executed
     * @param route Encoded route data (opaque bytes)
     * @param reward The reward structure
     * @param allowPartial Whether to accept partial funding
     * @param funder The address providing the funding (`msg.sender` for open, `order.user` for openFor)
     * @return intentHash Unique identifier of the created/existing intent
     * @return account Address of the intent's source (escrow) Account
     */
    function _publishAndFund(
        uint32 protocolVersion,
        uint64 source,
        uint64 destination,
        bytes memory route,
        Reward memory reward,
        bool allowPartial,
        address funder
    ) internal override returns (bytes32 intentHash, address account) {
        address implementation = _resolveImplementation(protocolVersion);

        bytes memory callData;
        if (funder == msg.sender) {
            callData = abi.encodeCall(
                IPortalPublishAndFund.publishAndFund,
                (protocolVersion, source, destination, route, reward, allowPartial)
            );
        } else {
            callData = abi.encodeCall(
                IPortalPublishAndFund.publishAndFundFor,
                (
                    protocolVersion,
                    source,
                    destination,
                    route,
                    reward,
                    allowPartial,
                    funder,
                    address(0)
                )
            );
        }

        bytes memory ret = _delegateToImplementation(implementation, callData);
        (intentHash, account) = abi.decode(ret, (bytes32, address));
    }

    /**
     * @notice {DestinationSettler} hook: fulfill + prove by delegatecalling the resolved Portal
     *         implementation's real `fulfillAndProve`.
     * @dev The `delegatecall` preserves `msg.sender` = the original solver, so {Inbox._fulfill}'s
     *      `safeTransferFrom(msg.sender, account, provided)` pulls the SOLVER's own input (see the
     *      contract-level note on why a plain self-CALL would be broken here). `msg.value` is likewise
     *      preserved for the native input leg + the proof-message fee.
     * @param protocolVersion Creator-declared Portal implementation version (selects the delegatecall target)
     * @param source Origin chain ID committed in the intent hash
     * @param destination Destination chain ID committed in the intent hash (must equal block.chainid)
     * @param route The route of the intent
     * @param reward The reward details (legs authenticated by the derived intent hash)
     * @param claimant Cross-VM compatible claimant identifier
     * @param providedAmounts Per-leg input the solver provides, index-aligned with `route.minTokens`
     * @param prover Prover (policy) to record the fulfillment into
     * @param sourceChainDomainID Bridge transport domain ID of the source chain
     * @param data Additional data for message formatting
     * @return The runtime's raw return data
     */
    function fulfillAndProve(
        uint32 protocolVersion,
        uint64 source,
        uint64 destination,
        Route memory route,
        Reward memory reward,
        bytes32 claimant,
        uint256[] memory providedAmounts,
        address prover,
        uint64 sourceChainDomainID,
        bytes memory data
    ) public payable override(DestinationSettler) returns (bytes memory) {
        address implementation = _resolveImplementation(protocolVersion);

        bytes memory callData = abi.encodeCall(
            IInbox.fulfillAndProve,
            (
                protocolVersion,
                source,
                destination,
                route,
                reward,
                claimant,
                providedAmounts,
                prover,
                sourceChainDomainID,
                data
            )
        );

        bytes memory ret = _delegateToImplementation(implementation, callData);
        return abi.decode(ret, (bytes));
    }

    /**
     * @notice Resolves the Portal implementation pinned to `protocolVersion` from the proxy registry.
     * @dev `address(this)` IS the {PortalProxy} here (two delegatecalls deep), so this is a plain external
     *      VIEW self-read of the proxy's own {IPortalProxy-versions} — it moves no funds, so the
     *      msg.sender-reset concern that governs the WRITE paths does not apply to it.
     * @param protocolVersion The creator-declared version to resolve.
     * @return implementation The pinned Portal implementation address.
     */
    function _resolveImplementation(
        uint32 protocolVersion
    ) private view returns (address implementation) {
        (implementation, ) = IPortalProxy(address(this)).versions(
            protocolVersion
        );
        if (implementation == address(0)) {
            revert IPortalProxy.UnknownProtocolVersion(protocolVersion);
        }
    }

    /**
     * @notice `delegatecall`s `implementation` with `callData`, bubbling the raw revert verbatim.
     * @dev Mirrors {PortalProxy._delegate}'s intent (preserve identity, bubble raw revert) but targets a
     *      DIFFERENT function selector than the enclosing call, so it forwards `callData` (not `msg.data`).
     *      A `delegatecall` preserves `address(this)`=proxy and `msg.sender`=original caller, which is what
     *      makes routing back into the core Portal logic correct where a plain self-CALL would not be. On
     *      success the ABI-encoded return data is handed back for the caller to decode.
     * @param implementation The resolved Portal implementation to execute in this (proxy) context.
     * @param callData The encoded target call.
     * @return The raw ABI-encoded return data.
     */
    function _delegateToImplementation(
        address implementation,
        bytes memory callData
    ) private returns (bytes memory) {
        (bool ok, bytes memory ret) = implementation.delegatecall(callData);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}
