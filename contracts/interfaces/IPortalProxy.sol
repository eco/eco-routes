/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Lifetime after which a registered protocol version is EXPIRED. A version is registered at `registeredAt`
// and stays valid for creating NEW intents until `registeredAt + VERSION_EXPIRY`. After that:
// {IIntentSource-publish} rejects new intents on the version (ProtocolVersionExpired), and the protocol
// owner gains the narrowly-scoped deployer-sweep authority on the EXISTING executeAsOwner escrow/proof lock
// (it can sweep an account whose intent is independently dead, never a live escrow). Settling / refunding /
// cooking existing intents keeps working forever regardless of expiry (an expired version stays REGISTERED
// — the registry is write-once, nothing is ever removed). A file-level constant (not a settable parameter),
// matching this codebase's immutable-trust-anchor ethos.
uint256 constant VERSION_EXPIRY = 365 days;

/**
 * @title IPortalProxy
 * @notice Minimal interface the versioned Portal implementations use to read the {PortalProxy} registry
 *         they run behind.
 * @dev A Portal implementation only ever executes via `delegatecall` FROM the {PortalProxy}, so inside the
 *      implementation `address(this)` IS the proxy. The implementation reads the version registry and the
 *      protocol owner by calling these functions against `address(this)` (an external call that lands on
 *      the proxy's own real functions, reading the proxy's namespaced storage / immutable owner) — used by
 *      {IIntentSource-publish} to validate the creator-declared version and by both `executeAsOwner`s to
 *      authorize the deployer sweep once a version is expired.
 */
/**
 * @notice Reverts unless `protocolVersion` is registered on `proxy` and not past its {VERSION_EXPIRY}.
 * @dev Shared by the source ({IntentSource}) and destination ({Inbox}) halves so a NEW intent can only be
 *      created under a live version. `proxy` is `address(this)` inside an implementation running via
 *      `delegatecall` from the {PortalProxy}. Unknown -> {IPortalProxy-UnknownProtocolVersion}; expired ->
 *      {IPortalProxy-ProtocolVersionExpired}.
 * @param proxy The {PortalProxy} holding the version registry (`address(this)` under delegatecall).
 * @param protocolVersion The version to validate.
 */
function requireValidProtocolVersion(
    address proxy,
    uint32 protocolVersion
) view {
    (address implementation, uint64 registeredAt) = IPortalProxy(proxy)
        .versions(protocolVersion);
    if (implementation == address(0)) {
        revert IPortalProxy.UnknownProtocolVersion(protocolVersion);
    }
    if (block.timestamp >= uint256(registeredAt) + VERSION_EXPIRY) {
        revert IPortalProxy.ProtocolVersionExpired(protocolVersion);
    }
}

/**
 * @notice Whether `protocolVersion` is registered on `proxy` AND past its {VERSION_EXPIRY}.
 * @dev Authorizes the protocol-owner deployer sweep on both `executeAsOwner` paths. An UNREGISTERED
 *      version is NOT expired (returns false): the sweep is only ever an alternate authority on a real,
 *      once-live version, never one that never existed.
 * @param proxy The {PortalProxy} holding the version registry (`address(this)` under delegatecall).
 * @param protocolVersion The version to check.
 * @return True if the version is registered and its expiry has elapsed.
 */
function isProtocolVersionExpired(
    address proxy,
    uint32 protocolVersion
) view returns (bool) {
    (address implementation, uint64 registeredAt) = IPortalProxy(proxy)
        .versions(protocolVersion);
    if (implementation == address(0)) {
        return false;
    }
    return block.timestamp >= uint256(registeredAt) + VERSION_EXPIRY;
}

interface IPortalProxy {
    /**
     * @notice A registered implementation for a protocol version and when it was registered.
     * @param implementation The Portal implementation contract for this version (`address(0)` if the
     *        version is unregistered).
     * @param registeredAt The block timestamp the version was registered (0 if unregistered).
     */
    struct VersionInfo {
        address implementation;
        uint64 registeredAt;
    }

    /**
     * @notice A version number has already been registered (registration is WRITE-ONCE).
     * @param version The version that was already taken.
     */
    error VersionAlreadyRegistered(uint32 version);

    /**
     * @notice A version was registered with the zero implementation address.
     */
    error ZeroImplementation();

    /**
     * @notice A call named a protocol version that has never been registered.
     * @param version The unregistered version.
     */
    error UnknownProtocolVersion(uint32 version);

    /**
     * @notice A new intent was published under a version that is past its {VERSION_EXPIRY}.
     * @param version The expired version.
     */
    error ProtocolVersionExpired(uint32 version);

    /**
     * @notice The caller is not the protocol owner.
     * @param caller The unauthorized caller.
     */
    error NotOwner(address caller);

    /**
     * @notice A new implementation version was registered.
     * @param version The version number registered.
     * @param implementation The implementation address bound to it.
     * @param registeredAt The registration timestamp.
     */
    event VersionRegistered(
        uint32 indexed version,
        address indexed implementation,
        uint64 registeredAt
    );

    /**
     * @notice Registers an implementation for a protocol version (owner-only, write-once).
     * @param version The version number to register.
     * @param implementation The Portal implementation contract for this version.
     */
    function registerVersion(uint32 version, address implementation) external;

    /**
     * @notice The implementation + registration time for a protocol version.
     * @param version The protocol version to look up.
     * @return implementation The implementation address (`address(0)` if unregistered).
     * @return registeredAt The registration timestamp (0 if unregistered).
     */
    function versions(
        uint32 version
    ) external view returns (address implementation, uint64 registeredAt);

    /**
     * @notice The protocol owner (may register versions and perform the expired-version deployer sweep).
     * @return The owner address.
     */
    function owner() external view returns (address);
}
