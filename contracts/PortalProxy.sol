/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPortalProxy} from "./interfaces/IPortalProxy.sol";
import {Intent} from "./types/Intent.sol";
import {OnchainCrossChainOrder, GaslessCrossChainOrder} from "./types/ERC7683.sol";

/**
 * @title PortalProxy
 * @notice The PERMANENT, stable-address front for the versioned Portal implementations.
 * @dev The protocol ships new Portal behaviour by REGISTERING new implementation versions, never by
 *      changing the address intents and accounts are anchored to. Every call is served by `delegatecall`
 *      into the implementation registered for the call's `protocolVersion`, so:
 *
 *        - The proxy's address is what solvers, keepers and per-intent Accounts trust forever.
 *        - Per-intent Account addresses derive from `address(this)` (the proxy — `delegatecall` preserves
 *          it) plus the implementation's Account clone template + CREATE2 prefix immutables. As long as
 *          every registered implementation is deployed with the SAME Account template + prefix (a protocol
 *          invariant the owner must uphold), an intent's Account address is IDENTICAL regardless of which
 *          implementation version is active — see {accountAddress}. This is the whole point of the proxy.
 *        - An intent is PINNED to its declared version: its hash commits `protocolVersion` (the first
 *          `Intent` field), and every lifecycle call re-declares it, so the intent is always served by the
 *          implementation it was created under, even after newer versions are registered or its own version
 *          expires.
 *
 *      STORAGE. The implementations execute in THIS contract's storage (delegatecall). The only
 *      implementation storage is a slot-0 mapping ({IntentSource.rewardStatuses}); to avoid any collision
 *      the proxy keeps its version registry in ERC-7201 NAMESPACED storage and its owner IMMUTABLE (in
 *      code, not storage), matching this codebase's immutable-trust-anchor ethos (it uses immutable
 *      whitelists, not OpenZeppelin `Ownable`).
 *
 *      DISPATCH. Most Portal entry points take `protocolVersion` as an explicit LEADING scalar (route
 *      stays opaque bytes at the source, so the version cannot be decoded from a nested struct on the
 *      `fund`/`settle`/`refund` paths). For those the {fallback} reads the version straight from
 *      `calldata[4:36]` and needs no per-function code. The exceptions get thin typed forwarders:
 *        - entry points taking a full `Intent` (its `protocolVersion` field selects the version), and
 *        - VERSION-AGNOSTIC helpers ({getRewardStatus}, {accountAddress}, {version}, {prove}) and the
 *          ERC-7683 adapter surface ({open}/{openFor}/{resolve}/{resolveFor}/{fill}) — dispatched to the
 *          LATEST registered implementation. These either only read shared proxy storage / derive an
 *          address (identical across implementations that share the Account template), or carry the pinned
 *          version inside their order/originData that the implementation itself validates and hashes with.
 */
contract PortalProxy is IPortalProxy {
    /// @notice The protocol owner: may register versions and perform the expired-version deployer sweep.
    /// @dev Immutable (set once at construction, never transferable) — matches the codebase's immutable
    ///      trust anchors and, being in code rather than storage, cannot collide with an implementation's
    ///      delegatecall storage writes.
    address private immutable OWNER;

    /// @custom:storage-location erc7201:eco.portal.proxy.registry
    struct RegistryStorage {
        mapping(uint32 => VersionInfo) versions;
        uint32 latestVersion;
    }

    /// @dev ERC-7201 namespaced slot for {RegistryStorage}:
    ///      keccak256(abi.encode(uint256(keccak256("eco.portal.proxy.registry")) - 1)) & ~0xff
    bytes32 private constant REGISTRY_SLOT =
        0x10a89caf7e3594b0f121a45225d831fd536e5f0685b5dcbe2b9da79a3ac6ab00;

    /**
     * @notice Sets the immutable protocol owner. Registers NO version — the implementation contracts do not
     *         exist yet at proxy-construction time, so {registerVersion} is called afterwards by the deploy
     *         script.
     * @param initialOwner The protocol owner address.
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) {
            revert ZeroImplementation();
        }
        OWNER = initialOwner;
    }

    // ---------------------------------------------------------------------------------------------------
    // Registry (real proxy functions — NOT forwarded)
    // ---------------------------------------------------------------------------------------------------

    /// @inheritdoc IPortalProxy
    function registerVersion(
        uint32 version,
        address implementation
    ) external {
        if (msg.sender != OWNER) {
            revert NotOwner(msg.sender);
        }
        if (implementation == address(0)) {
            revert ZeroImplementation();
        }
        RegistryStorage storage $ = _registry();
        // WRITE-ONCE: a version's implementation binding is immutable once set. Repointing a version that
        // live intents already reference would be a rug vector, so re-registration is rejected outright.
        if ($.versions[version].implementation != address(0)) {
            revert VersionAlreadyRegistered(version);
        }
        uint64 registeredAt = uint64(block.timestamp);
        $.versions[version] = VersionInfo({
            implementation: implementation,
            registeredAt: registeredAt
        });
        if (version > $.latestVersion) {
            $.latestVersion = version;
        }
        emit VersionRegistered(version, implementation, registeredAt);
    }

    /// @inheritdoc IPortalProxy
    function versions(
        uint32 version
    ) external view returns (address implementation, uint64 registeredAt) {
        VersionInfo storage info = _registry().versions[version];
        return (info.implementation, info.registeredAt);
    }

    /// @inheritdoc IPortalProxy
    function owner() external view returns (address) {
        return OWNER;
    }

    // ---------------------------------------------------------------------------------------------------
    // Forwarders for entry points carrying a full Intent (version = intent.protocolVersion)
    // ---------------------------------------------------------------------------------------------------

    function publish(Intent calldata intent) external {
        _delegate(_implementation(intent.protocolVersion));
    }

    function publishAndFund(
        Intent calldata intent,
        bool /* allowPartial */
    ) external payable {
        _delegate(_implementation(intent.protocolVersion));
    }

    function publishAndFundFor(
        Intent calldata intent,
        bool /* allowPartial */,
        address /* funder */,
        address /* permitContract */
    ) external payable {
        _delegate(_implementation(intent.protocolVersion));
    }

    function intentAccountAddress(Intent calldata intent) external {
        _delegate(_implementation(intent.protocolVersion));
    }

    function isIntentFunded(Intent calldata intent) external {
        _delegate(_implementation(intent.protocolVersion));
    }

    function getIntentHash(Intent calldata intent) external {
        _delegate(_implementation(intent.protocolVersion));
    }

    function executeAsOwner(
        Intent calldata intent,
        address /* runtime */,
        bytes calldata /* payload */
    ) external payable {
        _delegate(_implementation(intent.protocolVersion));
    }

    function fulfillAndSettle(
        Intent calldata intent,
        uint256[] calldata /* providedAmounts */,
        bytes32 /* claimant */
    ) external payable {
        _delegate(_implementation(intent.protocolVersion));
    }

    // ---------------------------------------------------------------------------------------------------
    // Forwarders for version-agnostic helpers + the ERC-7683 adapter surface (dispatched to LATEST)
    // ---------------------------------------------------------------------------------------------------

    function getRewardStatus(bytes32 /* intentHash */) external {
        _delegate(_latestImplementation());
    }

    function accountAddress(
        bytes32 /* intentHash */,
        uint64 /* roleChainId */
    ) external {
        _delegate(_latestImplementation());
    }

    function version() external {
        _delegate(_latestImplementation());
    }

    function prove(
        address /* prover */,
        uint64 /* sourceChainDomainID */,
        bytes32[] calldata /* intentHashes */,
        bytes calldata /* data */
    ) external payable {
        _delegate(_latestImplementation());
    }

    function open(OnchainCrossChainOrder calldata /* order */) external payable {
        _delegate(_latestImplementation());
    }

    function openFor(
        GaslessCrossChainOrder calldata /* order */,
        bytes calldata /* signature */,
        bytes calldata /* originFillerData */
    ) external payable {
        _delegate(_latestImplementation());
    }

    function resolve(OnchainCrossChainOrder calldata /* order */) external {
        _delegate(_latestImplementation());
    }

    function resolveFor(
        GaslessCrossChainOrder calldata /* order */,
        bytes calldata /* originFillerData */
    ) external {
        _delegate(_latestImplementation());
    }

    function fill(
        bytes32 /* orderId */,
        bytes calldata /* originData */,
        bytes calldata /* fillerData */
    ) external payable {
        _delegate(_latestImplementation());
    }

    // ---------------------------------------------------------------------------------------------------
    // Generic dispatch for every entry point taking a leading `uint32 protocolVersion`
    // ---------------------------------------------------------------------------------------------------

    /**
     * @notice Dispatches all entry points whose FIRST ABI argument is the `uint32 protocolVersion` scalar,
     *         plus any version-agnostic no-argument view not given a dedicated forwarder.
     * @dev For a function with a leading `uint32 protocolVersion` the version sits in the first ABI word
     *      after the selector, at `calldata[4:36]` (publish/fund/settle/refund/recover/fulfill/
     *      executeAsOwner/stream... decomposed forms) — read it and route to that implementation. A
     *      selector-only call (`4 <= length < 36`, i.e. a no-argument function such as `domainSeparatorV4`)
     *      carries no version and is version-agnostic, so it routes to the LATEST implementation. Fewer than
     *      4 bytes (incl. a bare value transfer) has no selector and reverts.
     */
    fallback() external payable {
        if (msg.data.length < 4) {
            revert UnknownProtocolVersion(0);
        }
        if (msg.data.length < 36) {
            // No-argument function (selector only): version-agnostic, serve from the latest implementation.
            _delegate(_latestImplementation());
        }
        uint32 protocolVersion = uint32(uint256(bytes32(msg.data[4:36])));
        _delegate(_implementation(protocolVersion));
    }

    // ---------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------

    /**
     * @notice Resolves the implementation for a version, reverting if it is not registered.
     * @dev Unregistered -> {UnknownProtocolVersion}. An EXPIRED (but registered) version still resolves —
     *      existing intents on a retired version must stay settleable/refundable/sweepable forever; only
     *      {IIntentSource-publish} additionally rejects an expired version for NEW intents.
     * @param protocolVersion The version to resolve.
     * @return impl The implementation address.
     */
    function _implementation(
        uint32 protocolVersion
    ) internal view returns (address impl) {
        impl = _registry().versions[protocolVersion].implementation;
        if (impl == address(0)) {
            revert UnknownProtocolVersion(protocolVersion);
        }
    }

    /**
     * @notice The latest registered implementation (for version-agnostic + ERC-7683 forwarders).
     * @dev Reverts {UnknownProtocolVersion} until at least one version is registered.
     * @return The latest implementation address.
     */
    function _latestImplementation() internal view returns (address) {
        return _implementation(_registry().latestVersion);
    }

    /**
     * @notice `delegatecall`s the current calldata to `impl` and bubbles the raw return/revert verbatim.
     * @param impl The implementation to execute in this proxy's context.
     */
    function _delegate(address impl) internal {
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    /// @notice Points a storage struct at the ERC-7201 namespaced registry slot.
    function _registry() private pure returns (RegistryStorage storage $) {
        assembly {
            $.slot := REGISTRY_SLOT
        }
    }
}
