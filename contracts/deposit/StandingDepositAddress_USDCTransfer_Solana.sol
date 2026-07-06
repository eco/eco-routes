// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StandingDepositAddress} from "./StandingDepositAddress.sol";
import {IIntentSource} from "../interfaces/IIntentSource.sol";
import {Reward, RewardToken, IntentLib} from "../types/Intent.sol";
import {Endian} from "../libs/Endian.sol";

/**
 * @title IStandingSolanaFactory
 * @notice Config surface the Solana standing factory exposes to its clone template.
 */
interface IStandingSolanaFactory {
    function SOURCE_TOKEN() external view returns (address);

    function DESTINATION_TOKEN() external view returns (bytes32);

    function PORTAL_ADDRESS() external view returns (address);

    function PROVER_ADDRESS() external view returns (address);

    function DESTINATION_PORTAL() external view returns (bytes32);

    function PORTAL_PDA() external view returns (bytes32);

    function EXECUTOR_ATA() external view returns (bytes32);

    function PROTOCOL_VERSION() external view returns (uint32);

    function REWARD_RATE() external view returns (uint256);
}

/**
 * @title StandingDepositAddress_USDCTransfer_Solana
 * @notice STANDING cross-chain streaming deposit template for USDC -> Solana: ONE standing intent per
 *         deposit address, settled with the plain {StreamingPolicy} (NOT the flash policy — escrow (EVM)
 *         and execution (Solana) live on different chains, so a solver genuinely fronts capital on Solana
 *         and is repaid from the EVM pool after the batch is bridged back).
 * @dev source = this EVM chain (holds the USDC reward pool); destination = Solana (1399811149). The reward
 *      is a SINGLE PURE-RATE leg on the source USDC (`rate = REWARD_RATE >= WAD`, `flat == 0`): the rate
 *      spread is the ONLY fee channel (a streaming `flat` is charged once per intent lifetime, wrong for a
 *      reusable deposit address). `publishAndFund` marks it `Funded` with zero pull; deposits are direct
 *      transfers into the pool ({sweep}); the whitelisted relay bridges Solana batch commitments via
 *      {IStreamingPolicy-recordBatch}; permissionless `settleStream` pays each solver `fulfilled * rate /
 *      WAD`; the keeper exits via `closeStream`.
 *
 *      SCOPE: the EVM half (publish / pool / relay-record / settle / close / epoch) is fully functional and
 *      testable now. The route bytes are a DETERMINISTIC PLACEHOLDER Borsh encoding (amount == 0, deadline
 *      == max) — the real re-fulfillable SVM streaming program (variable per-slice amount + actual SPL
 *      delivery) is a documented out-of-repo follow-up. The one-shot template's per-deposit u64
 *      `AmountTooLarge` guard is deleted (there is no per-deposit amount under streaming; the u64 SPL
 *      constraint is enforced per slice on the SVM side).
 */
contract StandingDepositAddress_USDCTransfer_Solana is StandingDepositAddress {
    // ============ Constants ============

    /// @notice Solana chain id.
    uint64 public constant DESTINATION_CHAIN = 1399811149;

    /// @notice Solana SPL Token Program ID.
    bytes32 public constant SPL_TOKEN_PROGRAM_ID =
        0x06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9;

    /// @notice Token decimals for USDC on Solana.
    uint8 public constant TOKEN_DECIMALS = 6;

    // ============ Immutables ============

    IStandingSolanaFactory internal immutable FACTORY;

    // ============ Storage ============

    /// @notice Whether the stream for a given epoch has been published/funded (idempotency hint).
    mapping(uint256 => bool) public opened;

    // ============ Constructor ============

    constructor() {
        FACTORY = IStandingSolanaFactory(msg.sender);
    }

    // ============ External ============

    /**
     * @notice Publish + fund the standing cross-chain streaming intent for the current epoch.
     * @return intentHash The standing intent hash.
     * @return pool The source-chain escrow pool Account (deposits are swept here).
     */
    function openStream()
        external
        nonReentrant
        returns (bytes32 intentHash, address pool)
    {
        return _openStreamInternal();
    }

    /// @notice The standing intent (so a keeper can call settleStream / closeStream).
    function getStandingIntent()
        external
        view
        returns (
            uint32 protocolVersion,
            uint64 source,
            uint64 destination,
            bytes32 routeHash,
            Reward memory reward
        )
    {
        protocolVersion = FACTORY.PROTOCOL_VERSION();
        source = uint64(block.chainid);
        destination = DESTINATION_CHAIN;
        routeHash = keccak256(_encodeRoute());
        reward = _buildReward();
    }

    // ============ Internal: base hooks ============

    function _factory() internal view override returns (address) {
        return address(FACTORY);
    }

    function _portalAddress() internal view override returns (address) {
        return FACTORY.PORTAL_ADDRESS();
    }

    function _sourceToken() internal view override returns (address) {
        return FACTORY.SOURCE_TOKEN();
    }

    function _depositPoolAccount() internal view override returns (address) {
        Reward memory reward = _buildReward();
        return
            IIntentSource(FACTORY.PORTAL_ADDRESS()).intentAccountAddress(
                FACTORY.PROTOCOL_VERSION(),
                uint64(block.chainid),
                DESTINATION_CHAIN,
                _encodeRoute(),
                reward
            );
    }

    function _currentEpochIntentHashes()
        internal
        view
        override
        returns (bytes32[] memory hashes)
    {
        hashes = new bytes32[](1);
        hashes[0] = IntentLib.hashIntent(
            FACTORY.PROTOCOL_VERSION(),
            uint64(block.chainid),
            DESTINATION_CHAIN,
            keccak256(_encodeRoute()),
            keccak256(abi.encode(_buildReward()))
        );
    }

    function _open() internal override {
        _openStreamInternal();
    }

    // ============ Internal: build + publish ============

    function _openStreamInternal()
        internal
        returns (bytes32 intentHash, address pool)
    {
        if (!initialized) revert NotInitialized();

        bytes memory routeBytes = _encodeRoute();
        Reward memory reward = _buildReward();

        // Rate-only leg => escrow target 0 => Funded with zero token pull. Idempotent while Initial/Funded.
        (intentHash, pool) = IIntentSource(FACTORY.PORTAL_ADDRESS())
            .publishAndFund(
                FACTORY.PROTOCOL_VERSION(),
                uint64(block.chainid),
                DESTINATION_CHAIN,
                routeBytes,
                reward,
                false
            );

        opened[epoch] = true;
    }

    function _buildReward() internal view returns (Reward memory reward) {
        RewardToken[] memory rw = new RewardToken[](1);
        rw[0] = RewardToken({
            token: FACTORY.SOURCE_TOKEN(),
            rate: FACTORY.REWARD_RATE(),
            flat: 0
        });
        reward = Reward({
            deadline: type(uint64).max,
            keeper: depositor,
            prover: FACTORY.PROVER_ADDRESS(),
            tokens: rw,
            hooks: ""
        });
    }

    /**
     * @notice Deterministic PLACEHOLDER Borsh route for the current epoch (amount == 0, deadline == max).
     * @dev Preserves the one-shot template's field layout exactly (only the salt/deadline/amount VALUES
     *      change), so the encoding is a valid, stable Borsh route the SVM program layout expects. The
     *      per-slice amount is chosen by the solver and enforced on the SVM side, so a baked placeholder is
     *      correct; the salt carries the epoch (via {_saltForEpoch}) so a `reopen` mints a fresh hash/pool.
     */
    function _encodeRoute() internal view returns (bytes memory) {
        bytes32 salt = _saltForEpoch();
        uint64 deadline = type(uint64).max;

        bytes32 destinationToken = FACTORY.DESTINATION_TOKEN();

        // SPL transfer_checked instruction data: discriminator + amount (u64 LE, placeholder 0) + decimals.
        bytes memory instructionData = abi.encodePacked(
            bytes1(0x0c),
            Endian.toLittleEndian64(0), // placeholder amount = 0
            TOKEN_DECIMALS
        );

        bytes memory calldataWithAccounts = abi.encodePacked(
            Endian.toLittleEndian32(uint32(instructionData.length)),
            instructionData,
            bytes1(0x04), // account_count
            Endian.toLittleEndian32(4), // accounts.length
            // accounts[0]: Executor ATA (source token account) — writable, not signer
            FACTORY.EXECUTOR_ATA(),
            bytes1(0x00),
            bytes1(0x01),
            // accounts[1]: Token mint — read-only, not signer
            destinationToken,
            bytes1(0x00),
            bytes1(0x00),
            // accounts[2]: Recipient ATA — writable, not signer
            destinationAddress,
            bytes1(0x00),
            bytes1(0x01),
            // accounts[3]: Executor authority (Portal PDA) — read-only, not signer
            FACTORY.PORTAL_PDA(),
            bytes1(0x00),
            bytes1(0x00)
        );

        return
            abi.encodePacked(
                salt,
                Endian.toLittleEndian64(deadline),
                FACTORY.DESTINATION_PORTAL(),
                Endian.toLittleEndian64(0), // native_amount = 0
                Endian.toLittleEndian32(1), // tokens.length = 1
                destinationToken,
                Endian.toLittleEndian64(0), // tokens[0].amount = 0 (placeholder)
                Endian.toLittleEndian32(1), // calls.length = 1
                SPL_TOKEN_PROGRAM_ID,
                Endian.toLittleEndian32(uint32(calldataWithAccounts.length)),
                calldataWithAccounts
            );
    }
}
