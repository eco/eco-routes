// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "../account/Clones.sol";
import {WAD} from "../types/Intent.sol";
import {StandingDepositAddress_USDCTransfer_Solana} from "./StandingDepositAddress_USDCTransfer_Solana.sol";

/**
 * @title StandingDepositFactory_USDCTransfer_Solana
 * @notice STANDING cross-chain streaming deposit factory for USDC -> Solana. Standalone (does NOT inherit
 *         {BaseDepositFactory} and deploys NO runtime — the Solana route is opaque Borsh executed by the
 *         out-of-repo SVM program). Config-shape mirror of the one-shot factory plus PROTOCOL_VERSION and
 *         REWARD_RATE (and dropping INTENT_DEADLINE_DURATION — deadlines are now `type(uint64).max`).
 * @dev PROVER_ADDRESS points at a {StreamingPolicy} (constructed with the whitelisted relay set by the
 *      deploy script). `REWARD_RATE >= WAD` is the solver spread (the ONLY fee channel); `REWARD_RATE ==
 *      WAD` is the zero-spread operator-run default.
 */
contract StandingDepositFactory_USDCTransfer_Solana {
    using Clones for address;

    // ============ Constants ============

    /// @notice Solana chain id.
    uint64 public constant DESTINATION_CHAIN = 1399811149;

    // ============ Immutables (IStandingSolanaFactory surface) ============

    address public immutable SOURCE_TOKEN;
    bytes32 public immutable DESTINATION_TOKEN;
    address public immutable PORTAL_ADDRESS;
    address public immutable PROVER_ADDRESS;
    bytes32 public immutable DESTINATION_PORTAL;
    bytes32 public immutable PORTAL_PDA;
    bytes32 public immutable EXECUTOR_ATA;
    uint32 public immutable PROTOCOL_VERSION;
    uint256 public immutable REWARD_RATE;

    address public immutable DEPOSIT_IMPLEMENTATION;

    // ============ Events ============

    event DepositContractDeployed(
        bytes32 indexed destinationAddress,
        address indexed depositAddress
    );

    // ============ Errors ============

    error InvalidSourceToken();
    error InvalidDestinationToken();
    error InvalidPortalAddress();
    error InvalidProverAddress();
    error InvalidDestinationPortal();
    error InvalidPortalPDA();
    error InvalidExecutorATA();
    error InvalidDestinationAddress();
    error RewardRateBelowWad(uint256 rate);

    // ============ Constructor ============

    constructor(
        address _sourceToken,
        bytes32 _destinationToken,
        address _portalAddress,
        address _proverAddress,
        bytes32 _destinationPortal,
        bytes32 _portalPDA,
        bytes32 _executorATA,
        uint32 _protocolVersion,
        uint256 _rewardRate
    ) {
        if (_sourceToken == address(0)) revert InvalidSourceToken();
        if (_destinationToken == bytes32(0)) revert InvalidDestinationToken();
        if (_portalAddress == address(0)) revert InvalidPortalAddress();
        if (_proverAddress == address(0)) revert InvalidProverAddress();
        if (_destinationPortal == bytes32(0)) revert InvalidDestinationPortal();
        if (_portalPDA == bytes32(0)) revert InvalidPortalPDA();
        if (_executorATA == bytes32(0)) revert InvalidExecutorATA();
        if (_rewardRate < WAD) revert RewardRateBelowWad(_rewardRate);

        SOURCE_TOKEN = _sourceToken;
        DESTINATION_TOKEN = _destinationToken;
        PORTAL_ADDRESS = _portalAddress;
        PROVER_ADDRESS = _proverAddress;
        DESTINATION_PORTAL = _destinationPortal;
        PORTAL_PDA = _portalPDA;
        EXECUTOR_ATA = _executorATA;
        PROTOCOL_VERSION = _protocolVersion;
        REWARD_RATE = _rewardRate;

        DEPOSIT_IMPLEMENTATION = address(
            new StandingDepositAddress_USDCTransfer_Solana()
        );
    }

    // ============ External ============

    /**
     * @notice Deploy a deterministic standing deposit address for a user.
     * @param destinationAddress Recipient's Associated Token Account (ATA) on Solana.
     * @param depositor Keeper / refund recipient on the source chain.
     * @return deployed The deployed clone address.
     */
    function deploy(
        bytes32 destinationAddress,
        address depositor
    ) external returns (address deployed) {
        if (destinationAddress == bytes32(0)) {
            revert InvalidDestinationAddress();
        }
        bytes32 salt = _getSalt(destinationAddress, depositor);
        deployed = DEPOSIT_IMPLEMENTATION.clone(salt);
        StandingDepositAddress_USDCTransfer_Solana(deployed).initialize(
            destinationAddress,
            depositor
        );
        emit DepositContractDeployed(destinationAddress, deployed);
    }

    /// @notice Predict a user's deterministic deposit address.
    function getDepositAddress(
        bytes32 destinationAddress,
        address depositor
    ) public view returns (address) {
        bytes32 salt = _getSalt(destinationAddress, depositor);
        return DEPOSIT_IMPLEMENTATION.predict(salt, bytes1(0xff));
    }

    /// @notice Whether a user's deposit address has been deployed.
    function isDeployed(
        bytes32 destinationAddress,
        address depositor
    ) external view returns (bool) {
        return getDepositAddress(destinationAddress, depositor).code.length > 0;
    }

    /**
     * @notice Full factory configuration (discovery).
     */
    function getConfiguration()
        external
        view
        returns (
            uint64 destinationChain,
            address sourceToken,
            bytes32 destinationToken,
            address portalAddress,
            address proverAddress,
            bytes32 destinationPortal,
            bytes32 portalPDA,
            bytes32 executorATA,
            uint32 protocolVersion,
            uint256 rewardRate
        )
    {
        return (
            DESTINATION_CHAIN,
            SOURCE_TOKEN,
            DESTINATION_TOKEN,
            PORTAL_ADDRESS,
            PROVER_ADDRESS,
            DESTINATION_PORTAL,
            PORTAL_PDA,
            EXECUTOR_ATA,
            PROTOCOL_VERSION,
            REWARD_RATE
        );
    }

    // ============ Internal ============

    function _getSalt(
        bytes32 destinationAddress,
        address depositor
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(destinationAddress, depositor));
    }
}
