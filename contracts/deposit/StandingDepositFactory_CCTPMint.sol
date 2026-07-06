// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "../account/Clones.sol";
import {WAD} from "../types/Intent.sol";
import {CCTPBurnRuntime} from "../runtime/CCTPBurnRuntime.sol";
import {StandingDepositAddress_CCTPMint} from "./StandingDepositAddress_CCTPMint.sol";

/**
 * @title StandingDepositFactory_CCTPMint
 * @notice Shared base for the STANDING CCTP + Gateway deposit factories (Arc and GatewayERC20). Deploys
 *         deterministic (CREATE2) deposit clones of the ONE shared {StandingDepositAddress_CCTPMint}
 *         template, and holds the family config as public immutables (the template reads them via the
 *         {IStandingCCTPFactory} getters).
 * @dev NEW standing factory — it does NOT touch the immutable one-shot {BaseDepositFactory} /
 *      DepositFactory_CCTPMint_* contracts. It deploys its OWN source-side {CCTPBurnRuntime} in the
 *      constructor (mirroring how {BaseDepositFactory} deploys {MulticallRuntime}); the destination-side
 *      {GatewayDepositRuntime} lives on the destination chain, so it is a config address (deployed by the
 *      deploy script and committed into intent 2's route hash -> account2).
 *
 *      Fee is the reward-leg rate spread ONLY (never a payload fee): `RATE_1 >= WAD` is the source-pool
 *      spread; `RATE_2 == WAD` gives the user the full CCTP net. Constructor sanity checks reject the
 *      config footguns that would BRICK a published pool: `RATE_* < WAD` (slice > pool, underfunded
 *      advance) and `MAX_FEE_BPS >= FEE_DENOMINATOR` (CCTP maxFee >= slice, burn rejected).
 */
abstract contract StandingDepositFactory_CCTPMint {
    using Clones for address;

    // ============ Config passed to the base ctor ============

    struct CCTPConfig {
        address sourceToken;
        address portal;
        uint32 protocolVersion;
        address streamingFlashPolicy;
        address gatewayDepositRuntime;
        uint64 destinationChainId;
        uint32 destinationDomain;
        address cctpTokenMessenger;
        address destUsdc;
        address gateway;
        uint256 rate1;
        uint256 rate2;
        uint256 minSlice1;
        uint256 minSlice2;
        uint256 maxFeeBps;
    }

    // ============ Constants ============

    /// @notice Denominator for `MAX_FEE_BPS` (matches CCTP / the one-shot templates).
    uint256 public constant FEE_DENOMINATOR = 100_000;

    // ============ Immutables (IStandingCCTPFactory surface) ============

    address public immutable SOURCE_TOKEN;
    address public immutable PORTAL_ADDRESS;
    uint32 public immutable PROTOCOL_VERSION;
    address public immutable STREAMING_FLASH_POLICY;
    address public immutable CCTP_BURN_RUNTIME;
    address public immutable GATEWAY_DEPOSIT_RUNTIME;
    uint64 public immutable DESTINATION_CHAIN_ID;
    uint32 public immutable DESTINATION_DOMAIN;
    address public immutable CCTP_TOKEN_MESSENGER;
    address public immutable DEST_USDC;
    address public immutable GATEWAY_ADDRESS;
    uint256 public immutable RATE_1;
    uint256 public immutable RATE_2;
    uint256 public immutable MIN_SLICE_1;
    uint256 public immutable MIN_SLICE_2;
    uint256 public immutable MAX_FEE_BPS;

    /// @notice The shared standing deposit template cloned per (destinationAddress, depositor).
    address public immutable DEPOSIT_IMPLEMENTATION;

    // ============ Events ============

    event DepositContractDeployed(
        address indexed destinationAddress,
        address indexed depositContract
    );

    // ============ Errors ============

    error InvalidSourceToken();
    error InvalidPortalAddress();
    error InvalidStreamingFlashPolicy();
    error InvalidGatewayDepositRuntime();
    error InvalidDestinationChainId();
    error InvalidCCTPTokenMessenger();
    error InvalidDestUsdc();
    error InvalidGatewayAddress();
    /// @notice `rate < WAD` would make the slice exceed the pool and underfund the direct-mode advance.
    error RateBelowWad(uint256 rate);
    /// @notice `maxFeeBps >= FEE_DENOMINATOR` makes the CCTP maxFee >= slice, so the burn is rejected.
    error MaxFeeBpsTooLarge(uint256 maxFeeBps);

    // ============ Constructor ============

    constructor(CCTPConfig memory cfg) {
        if (cfg.sourceToken == address(0)) revert InvalidSourceToken();
        if (cfg.portal == address(0)) revert InvalidPortalAddress();
        if (cfg.streamingFlashPolicy == address(0)) {
            revert InvalidStreamingFlashPolicy();
        }
        if (cfg.gatewayDepositRuntime == address(0)) {
            revert InvalidGatewayDepositRuntime();
        }
        if (cfg.destinationChainId == 0) revert InvalidDestinationChainId();
        if (cfg.cctpTokenMessenger == address(0)) {
            revert InvalidCCTPTokenMessenger();
        }
        if (cfg.destUsdc == address(0)) revert InvalidDestUsdc();
        if (cfg.gateway == address(0)) revert InvalidGatewayAddress();
        if (cfg.rate1 < WAD) revert RateBelowWad(cfg.rate1);
        if (cfg.rate2 < WAD) revert RateBelowWad(cfg.rate2);
        if (cfg.maxFeeBps >= FEE_DENOMINATOR) {
            revert MaxFeeBpsTooLarge(cfg.maxFeeBps);
        }

        SOURCE_TOKEN = cfg.sourceToken;
        PORTAL_ADDRESS = cfg.portal;
        PROTOCOL_VERSION = cfg.protocolVersion;
        STREAMING_FLASH_POLICY = cfg.streamingFlashPolicy;
        GATEWAY_DEPOSIT_RUNTIME = cfg.gatewayDepositRuntime;
        DESTINATION_CHAIN_ID = cfg.destinationChainId;
        DESTINATION_DOMAIN = cfg.destinationDomain;
        CCTP_TOKEN_MESSENGER = cfg.cctpTokenMessenger;
        DEST_USDC = cfg.destUsdc;
        GATEWAY_ADDRESS = cfg.gateway;
        RATE_1 = cfg.rate1;
        RATE_2 = cfg.rate2;
        MIN_SLICE_1 = cfg.minSlice1;
        MIN_SLICE_2 = cfg.minSlice2;
        MAX_FEE_BPS = cfg.maxFeeBps;

        // Deploy the source-side balance-reading burn runtime (config-only payloads reference it).
        CCTP_BURN_RUNTIME = address(new CCTPBurnRuntime());

        // Deploy the shared standing template implementation cloned per user.
        DEPOSIT_IMPLEMENTATION = address(new StandingDepositAddress_CCTPMint());
    }

    // ============ External ============

    /**
     * @notice Deploy a deterministic standing deposit address for a user.
     * @param destinationAddress User's destination (Gateway recipient) address.
     * @param depositor Keeper / refund recipient on the source chain.
     * @return deployed The deployed clone address.
     */
    function deploy(
        address destinationAddress,
        address depositor
    ) external returns (address deployed) {
        bytes32 salt = _getSalt(destinationAddress, depositor);
        deployed = DEPOSIT_IMPLEMENTATION.clone(salt);
        StandingDepositAddress_CCTPMint(deployed).initialize(
            bytes32(uint256(uint160(destinationAddress))),
            depositor
        );
        emit DepositContractDeployed(destinationAddress, deployed);
    }

    /// @notice Predict a user's deterministic deposit address.
    function getDepositAddress(
        address destinationAddress,
        address depositor
    ) public view returns (address) {
        bytes32 salt = _getSalt(destinationAddress, depositor);
        return DEPOSIT_IMPLEMENTATION.predict(salt, bytes1(0xff));
    }

    /// @notice Whether a user's deposit address has been deployed.
    function isDeployed(
        address destinationAddress,
        address depositor
    ) external view returns (bool) {
        return getDepositAddress(destinationAddress, depositor).code.length > 0;
    }

    /// @notice The full family config (discovery for solvers/keepers).
    function getConfiguration() external view returns (CCTPConfig memory cfg) {
        cfg = CCTPConfig({
            sourceToken: SOURCE_TOKEN,
            portal: PORTAL_ADDRESS,
            protocolVersion: PROTOCOL_VERSION,
            streamingFlashPolicy: STREAMING_FLASH_POLICY,
            gatewayDepositRuntime: GATEWAY_DEPOSIT_RUNTIME,
            destinationChainId: DESTINATION_CHAIN_ID,
            destinationDomain: DESTINATION_DOMAIN,
            cctpTokenMessenger: CCTP_TOKEN_MESSENGER,
            destUsdc: DEST_USDC,
            gateway: GATEWAY_ADDRESS,
            rate1: RATE_1,
            rate2: RATE_2,
            minSlice1: MIN_SLICE_1,
            minSlice2: MIN_SLICE_2,
            maxFeeBps: MAX_FEE_BPS
        });
    }

    // ============ Internal ============

    function _getSalt(
        address destinationAddress,
        address depositor
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(destinationAddress, depositor));
    }
}
