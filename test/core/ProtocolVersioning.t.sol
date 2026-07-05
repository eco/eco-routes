// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "../BaseTest.sol";
import {IIntentSource} from "../../contracts/interfaces/IIntentSource.sol";
import {IInbox} from "../../contracts/interfaces/IInbox.sol";
import {IPortalProxy, VERSION_EXPIRY} from "../../contracts/interfaces/IPortalProxy.sol";
import {PortalProxy} from "../../contracts/PortalProxy.sol";
import {Portal} from "../../contracts/Portal.sol";
import {ERC7683Implementation} from "../../contracts/ERC7683/ERC7683Implementation.sol";
import {Intent, Reward, RewardToken} from "../../contracts/types/Intent.sol";
import {Call} from "../../contracts/interfaces/IRuntime.sol";

/**
 * @title ProtocolVersioningTest
 * @notice PR9 coverage: the PortalProxy version registry (write-once, owner-only), version-pinned dispatch,
 *         publish version validation, per-intent Account address stability across implementation versions,
 *         and the expired-version deployer sweep (an alternate authority on the EXISTING, unchanged
 *         executeAsOwner escrow/proof lock — never a way around it).
 * @dev Runs with `block.chainid == CHAIN_ID`. `deployer` is the PortalProxy's protocol owner (BaseTest).
 */
contract ProtocolVersioningTest is BaseTest {
    uint32 internal constant V2 = 2;

    function setUp() public override {
        vm.chainId(uint256(CHAIN_ID));
        super.setUp();
        _mintAndApprove(keeper, MINT_AMOUNT);
        _fundUserNative(keeper, 10 ether);
    }

    // Empty program for owner-cook / sweep calls (MulticallRuntime decodes an empty Call[] as a no-op).
    function _noop() internal pure returns (bytes memory) {
        return abi.encode(new Call[](0));
    }

    // A copy of the default intent with no reward legs (a deposit/owner-cook intent — never locked).
    function _emptyReward() internal view returns (Intent memory x) {
        x = intent;
        x.reward.tokens = new RewardToken[](0);
    }

    function _versionRegisteredAt(uint32 v) internal view returns (uint64 at) {
        (, at) = portalProxy.versions(v);
    }

    // -----------------------------------------------------------------------------------------------
    // Registry — write-once, owner-only
    // -----------------------------------------------------------------------------------------------

    function test_registerVersion_writeOnce_reverts() public {
        vm.prank(deployer);
        portalProxy.registerVersion(V2, portalImplementation);

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPortalProxy.VersionAlreadyRegistered.selector,
                V2
            )
        );
        portalProxy.registerVersion(V2, portalImplementation);
    }

    function test_registerVersion_v1_alreadyRegistered_reverts() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPortalProxy.VersionAlreadyRegistered.selector,
                PROTOCOL_VERSION
            )
        );
        portalProxy.registerVersion(PROTOCOL_VERSION, portalImplementation);
    }

    function test_registerVersion_zeroImplementation_reverts() public {
        vm.prank(deployer);
        vm.expectRevert(IPortalProxy.ZeroImplementation.selector);
        portalProxy.registerVersion(V2, address(0));
    }

    function test_registerVersion_onlyOwner_reverts() public {
        vm.prank(otherPerson);
        vm.expectRevert(
            abi.encodeWithSelector(IPortalProxy.NotOwner.selector, otherPerson)
        );
        portalProxy.registerVersion(V2, portalImplementation);
    }

    function test_versions_getter() public view {
        (address impl, uint64 at) = portalProxy.versions(PROTOCOL_VERSION);
        assertEq(impl, portalImplementation);
        assertGt(at, 0);

        (address none, uint64 zero) = portalProxy.versions(99);
        assertEq(none, address(0));
        assertEq(zero, 0);
    }

    function test_owner_isImmutableDeployer() public view {
        assertEq(portalProxy.owner(), deployer);
    }

    // -----------------------------------------------------------------------------------------------
    // Dispatch + publish validation
    // -----------------------------------------------------------------------------------------------

    function test_dispatch_reachesImplementation() public {
        vm.prank(keeper);
        intentSource.publishAndFund(intent, false);
        assertEq(
            uint256(intentSource.getRewardStatus(_hashIntent(intent))),
            uint256(IIntentSource.Status.Funded)
        );
    }

    function test_publish_unregisteredVersion_reverts() public {
        Intent memory x = intent;
        x.protocolVersion = 99;
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPortalProxy.UnknownProtocolVersion.selector,
                uint32(99)
            )
        );
        intentSource.publishAndFund(x, false);
    }

    function test_publish_expiredVersion_reverts() public {
        // Register a second version, warp exactly to its expiry, and try to publish a NEW intent on it.
        vm.prank(deployer);
        portalProxy.registerVersion(V2, portalImplementation);
        uint64 at = _versionRegisteredAt(V2);
        vm.warp(uint256(at) + VERSION_EXPIRY);

        Intent memory x = intent;
        x.protocolVersion = V2;
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPortalProxy.ProtocolVersionExpired.selector,
                V2
            )
        );
        intentSource.publishAndFund(x, false);
    }

    // -----------------------------------------------------------------------------------------------
    // Account-address stability across implementation versions
    // -----------------------------------------------------------------------------------------------

    /// @notice The per-intent Account address depends on the proxy (address(this) under delegatecall) and
    ///         the SHARED Account implementation, NOT on which Portal version is active. Registering a
    ///         DIFFERENT Portal implementation (built on the same shared Account implementation) as a newer
    ///         version must not move any account address.
    function test_accountAddressStableAcrossImplementationVersions() public {
        Intent memory x = intent;
        x.source = 10;
        x.destination = 20;
        bytes32 hash = _hashIntent(x);

        address addrV1 = portal.accountAddress(hash, x.source);

        // A genuinely different Portal implementation, sharing the same Account clone template.
        Portal impl2 = new Portal(accountImplementation, address(new ERC7683Implementation()));
        assertTrue(
            address(impl2) != portalImplementation,
            "impl2 must differ from v1"
        );
        vm.prank(deployer);
        portalProxy.registerVersion(V2, address(impl2));

        // accountAddress routes to the LATEST implementation (now v2); the address must be identical.
        address addrV2 = portal.accountAddress(hash, x.source);
        assertEq(
            addrV1,
            addrV2,
            "account address must be stable across implementation versions"
        );
    }

    // -----------------------------------------------------------------------------------------------
    // Deployer sweep — SOURCE side (alternate authority on the UNCHANGED escrow/proof lock)
    // -----------------------------------------------------------------------------------------------

    /// @notice (a) Before expiry the protocol owner is NOT an authority — only the keeper can cook.
    function test_deployerSweep_source_beforeExpiry_reverts() public {
        Intent memory x = _emptyReward(); // never locked, so only the auth gate matters here
        vm.prank(deployer); // proxy owner, but v1 is not expired yet
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.NotAccountOwner.selector,
                deployer
            )
        );
        intentSource.executeAsOwner(x, address(multicallRuntime), _noop());
    }

    /// @notice (b) After expiry the owner CAN sweep an independently-dead (empty-reward) account.
    function test_deployerSweep_source_afterExpiry_deadAccount_succeeds() public {
        Intent memory x = _emptyReward();
        address account = portal.accountAddress(_hashIntent(x), x.source);
        tokenA.mint(account, 500); // a stray token to sweep out

        uint64 at = _versionRegisteredAt(PROTOCOL_VERSION);
        vm.warp(uint256(at) + VERSION_EXPIRY + 1);

        Call[] memory sweep = new Call[](1);
        sweep[0] = Call({
            target: address(tokenA),
            value: 0,
            data: abi.encodeWithSignature(
                "transfer(address,uint256)",
                deployer,
                uint256(500)
            )
        });

        uint256 before = tokenA.balanceOf(deployer);
        vm.prank(deployer);
        intentSource.executeAsOwner(x, address(multicallRuntime), abi.encode(sweep));
        assertEq(tokenA.balanceOf(deployer), before + 500);
    }

    /// @notice (c) After expiry the owner is STILL blocked by AccountLocked while the reward is LIVE (has
    ///         legs and is before its deadline) — expiry alone is never sufficient.
    function test_deployerSweep_source_afterExpiry_liveEscrow_stillLocked() public {
        Intent memory x = intent;
        // Reward deadline far beyond the version expiry so the reward is still live after we warp.
        x.reward.deadline = uint64(block.timestamp + 800 days);
        vm.prank(keeper);
        intentSource.publishAndFund(x, false);

        uint64 at = _versionRegisteredAt(PROTOCOL_VERSION);
        vm.warp(uint256(at) + VERSION_EXPIRY + 1); // past version expiry, before reward deadline

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IIntentSource.AccountLocked.selector,
                _hashIntent(x)
            )
        );
        intentSource.executeAsOwner(x, address(multicallRuntime), _noop());
    }

    /// @notice (c') After expiry the owner is STILL blocked by AccountLocked while a valid destination proof
    ///         exists (a solver may be owed), even past the reward deadline.
    function test_deployerSweep_source_afterExpiry_validProof_stillLocked() public {
        vm.prank(keeper);
        intentSource.publishAndFund(intent, false);
        bytes32 hash = _hashIntent(intent);
        _addProof(hash, CHAIN_ID, claimant);

        uint64 at = _versionRegisteredAt(PROTOCOL_VERSION);
        vm.warp(uint256(at) + VERSION_EXPIRY + 1);

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IIntentSource.AccountLocked.selector, hash)
        );
        intentSource.executeAsOwner(intent, address(multicallRuntime), _noop());
    }

    // -----------------------------------------------------------------------------------------------
    // Deployer sweep — DESTINATION side (cross-chain only, for the deployer too)
    // -----------------------------------------------------------------------------------------------

    function test_deployerSweep_dest_crossChain_beforeExpiry_reverts() public {
        Intent memory x = intent;
        x.source = 777; // cross-chain: this chain is purely the destination
        x.destination = CHAIN_ID;
        bytes32 rewardHash = keccak256(abi.encode(x.reward));

        vm.prank(deployer); // owner, but not expired and not route.keeper
        vm.expectRevert(
            abi.encodeWithSelector(IInbox.NotAccountKeeper.selector, deployer)
        );
        portal.executeAsOwner(
            x.protocolVersion,
            x.source,
            x.route,
            rewardHash,
            address(multicallRuntime),
            _noop()
        );
    }

    function test_deployerSweep_dest_crossChain_afterExpiry_succeeds() public {
        Intent memory x = intent;
        x.source = 777;
        x.destination = CHAIN_ID;
        bytes32 rewardHash = keccak256(abi.encode(x.reward));

        uint64 at = _versionRegisteredAt(PROTOCOL_VERSION);
        vm.warp(uint256(at) + VERSION_EXPIRY + 1);

        vm.prank(deployer);
        portal.executeAsOwner(
            x.protocolVersion,
            x.source,
            x.route,
            rewardHash,
            address(multicallRuntime),
            _noop()
        );
        address account = portal.accountAddress(_hashIntent(x), x.destination);
        assertGt(account.code.length, 0, "dest account must be deployed");
    }

    /// @notice The cross-chain-only restriction applies to the deployer too: a same-chain dest sweep is
    ///         rejected (leftover retrieval must go through the escrow-aware source path).
    function test_deployerSweep_dest_sameChain_rejected() public {
        Intent memory x = intent; // source == destination == CHAIN_ID
        bytes32 rewardHash = keccak256(abi.encode(x.reward));

        uint64 at = _versionRegisteredAt(PROTOCOL_VERSION);
        vm.warp(uint256(at) + VERSION_EXPIRY + 1);

        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IInbox.SourceChainOwnerOnly.selector,
                x.source
            )
        );
        portal.executeAsOwner(
            x.protocolVersion,
            x.source,
            x.route,
            rewardHash,
            address(multicallRuntime),
            _noop()
        );
    }
}
