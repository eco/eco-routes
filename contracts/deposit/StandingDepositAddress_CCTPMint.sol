// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StandingDepositAddress} from "./StandingDepositAddress.sol";
import {IIntentSource} from "../interfaces/IIntentSource.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount, IntentLib} from "../types/Intent.sol";

/**
 * @title IStandingCCTPFactory
 * @notice Config surface both CCTP standing factories (Arc + GatewayERC20) expose to the shared template.
 * @dev Read as individual immutable getters (avoids a 16-field `getConfiguration` tuple / stack-too-deep).
 */
interface IStandingCCTPFactory {
    function SOURCE_TOKEN() external view returns (address);

    function PORTAL_ADDRESS() external view returns (address);

    function PROTOCOL_VERSION() external view returns (uint32);

    function STREAMING_FLASH_POLICY() external view returns (address);

    function CCTP_BURN_RUNTIME() external view returns (address);

    function GATEWAY_DEPOSIT_RUNTIME() external view returns (address);

    function DESTINATION_CHAIN_ID() external view returns (uint64);

    function DESTINATION_DOMAIN() external view returns (uint32);

    function CCTP_TOKEN_MESSENGER() external view returns (address);

    function DEST_USDC() external view returns (address);

    function GATEWAY_ADDRESS() external view returns (address);

    function RATE_1() external view returns (uint256);

    function RATE_2() external view returns (uint256);

    function MIN_SLICE_1() external view returns (uint256);

    function MIN_SLICE_2() external view returns (uint256);

    function MAX_FEE_BPS() external view returns (uint256);
}

/**
 * @title StandingDepositAddress_CCTPMint
 * @notice STANDING two-pool deposit template for CCTP + Gateway deposits, shared by BOTH the Arc and the
 *         GatewayERC20 families (the only differences are factory config: token addresses, chain ids, and
 *         the reward-leg rates).
 * @dev Migrates the one-shot "publish+fund a FRESH intent per deposit" model onto TWO STANDING
 *      {StreamingFlashPolicy} pools:
 *
 *        INTENT 1 (CCTP burn) — a same-chain pool on the SOURCE chain (`source == destination ==
 *        block.chainid`). Its runtime is {CCTPBurnRuntime}; the payload commits `bytes32(account2)` as the
 *        CCTP `mintRecipient`. Rate-only reward leg on the source USDC => `publishAndFund` marks it
 *        `Funded` with ZERO token pull. Deposits are swept into its escrow Account and drawn down by
 *        solver-driven `flashSlice` in DIRECT mode (reward token == input token == USDC, zero solver
 *        capital); the slice is burned via CCTP to `account2` and the margin (the rate spread, if any) is
 *        the solver/protocol fee.
 *
 *        INTENT 2 (Gateway deposit) — a same-chain pool on the DESTINATION chain (`source == destination ==
 *        DESTINATION_CHAIN_ID`). This is the FIX for the one-shot templates' latent bug, which committed
 *        `source = block.chainid` while the CCTP mint (its escrow) lands on the destination — every
 *        source-side settle op is `onlySourceChain(source)` and could never run where the mint is (masked
 *        in tests only by forcing the two chain ids equal). Its runtime is {GatewayDepositRuntime}; the
 *        rate is `WAD` (the user receives the full CCTP net). The source clone `publish`es it (ungated) for
 *        discovery and to pin `account2`; it is actually driven by `flashSlice` on the destination chain.
 *
 *      account2 is STABLE (its hash has no timestamp), so intent 1 can bake a fixed `mintRecipient` with no
 *      circularity. Fees are ONLY the reward-leg rate spread (`rate >= WAD`), never a payload fee — payloads
 *      commit CONFIG ONLY. The keeper exit is {IIntentSource-closeStream} per pool; deadlines are
 *      `type(uint64).max` so the permissionless post-deadline refund can never terminate a pool.
 *
 *      CROSS-CHAIN CAVEAT: intent 2's escrow (the CCTP mint) lives on the destination chain, so its
 *      `closeStream`, its status, and its dust-reclaim are all destination-chain keeper actions. {reopen}'s
 *      gate therefore only checks intent 1 (the source pool) — intent 2's destination-side `Refunded`
 *      status is not readable here. Rotate epochs only after in-flight CCTP has drained (a late mint under
 *      a rotated-away epoch lands at a now-terminal account2, recoverable only via destination
 *      `recoverToken`).
 */
contract StandingDepositAddress_CCTPMint is StandingDepositAddress {
    // ============ Immutables ============

    IStandingCCTPFactory internal immutable FACTORY;

    // ============ Storage ============

    /// @notice Whether the streams for a given epoch have been published/funded (idempotency hint).
    mapping(uint256 => bool) public opened;

    // ============ Constructor ============

    constructor() {
        FACTORY = IStandingCCTPFactory(msg.sender);
    }

    // ============ External ============

    /**
     * @notice Publish + fund both standing pools for the current epoch (permissionless, idempotent).
     * @return account1 The source CCTP-burn pool Account (deposits are swept here).
     * @return account2 The destination Gateway-deposit pool Account (the CCTP mint recipient).
     */
    function openStreams()
        external
        nonReentrant
        returns (address account1, address account2)
    {
        return _openStreamsInternal();
    }

    /// @notice The two standing intents for the current epoch (so a keeper can call closeStream/reopen).
    function getStandingIntents()
        external
        view
        returns (Intent memory intent1, Intent memory intent2)
    {
        address account2;
        (, account2, intent1, intent2) = _accounts();
    }

    /// @notice The two pool Accounts for the current epoch: (source burn pool, destination gateway pool).
    function getAccounts()
        external
        view
        returns (address account1, address account2)
    {
        (account1, account2, , ) = _accounts();
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
        (address account1, , , ) = _accounts();
        return account1;
    }

    /// @dev Only intent 1 (the SOURCE pool) is gated on reopen — intent 2's escrow/status live on the
    ///      destination chain and are reclaimed/closed there (see the contract-level caveat).
    function _currentEpochIntentHashes()
        internal
        view
        override
        returns (bytes32[] memory hashes)
    {
        (, , Intent memory i1, ) = _accounts();
        hashes = new bytes32[](1);
        hashes[0] = _intentHash(i1);
    }

    function _open() internal override {
        _openStreamsInternal();
    }

    // ============ Internal: build + publish ============

    function _openStreamsInternal()
        internal
        returns (address account1, address account2)
    {
        if (!initialized) revert NotInitialized();

        Intent memory i1;
        Intent memory i2;
        (account1, account2, i1, i2) = _accounts();

        if (!opened[epoch]) {
            IIntentSource portal = IIntentSource(FACTORY.PORTAL_ADDRESS());

            // Intent 2 (destination pool): publish only (ungated). Its escrow is the CCTP mint delivered
            // by direct transfer, never a Portal pull, so it is NOT funded here.
            portal.publish(
                i2.protocolVersion,
                i2.source,
                i2.destination,
                abi.encode(i2.route),
                i2.reward
            );

            // Intent 1 (source pool): publish + fund. Rate-only leg => escrow target 0 => Funded, zero pull.
            portal.publishAndFund(
                i1.protocolVersion,
                i1.source,
                i1.destination,
                abi.encode(i1.route),
                i1.reward,
                false
            );

            opened[epoch] = true;
        }
    }

    /// @notice Build both intents and resolve both pool Accounts for the current epoch.
    function _accounts()
        internal
        view
        returns (
            address account1,
            address account2,
            Intent memory intent1,
            Intent memory intent2
        )
    {
        IIntentSource portal = IIntentSource(FACTORY.PORTAL_ADDRESS());

        intent2 = _buildIntent2();
        account2 = portal.intentAccountAddress(
            intent2.protocolVersion,
            intent2.source,
            intent2.destination,
            abi.encode(intent2.route),
            intent2.reward
        );

        intent1 = _buildIntent1(account2);
        account1 = portal.intentAccountAddress(
            intent1.protocolVersion,
            intent1.source,
            intent1.destination,
            abi.encode(intent1.route),
            intent1.reward
        );
    }

    /// @notice Intent 2: the destination-chain Gateway-deposit pool (same-chain on DESTINATION_CHAIN_ID).
    function _buildIntent2() internal view returns (Intent memory intent) {
        address destUsdc = FACTORY.DEST_USDC();
        uint64 destChain = FACTORY.DESTINATION_CHAIN_ID();

        TokenAmount[] memory mo = new TokenAmount[](1);
        mo[0] = TokenAmount({token: destUsdc, amount: FACTORY.MIN_SLICE_2()});

        Route memory route = Route({
            salt: _saltForEpoch(),
            deadline: type(uint64).max,
            portal: FACTORY.PORTAL_ADDRESS(),
            keeper: depositor,
            runtime: FACTORY.GATEWAY_DEPOSIT_RUNTIME(),
            // CONFIG ONLY: (token, gateway, user recipient). No amount (read live by the runtime).
            payload: abi.encode(
                destUsdc,
                FACTORY.GATEWAY_ADDRESS(),
                address(uint160(uint256(destinationAddress)))
            ),
            minTokens: mo
        });

        RewardToken[] memory rw = new RewardToken[](1);
        rw[0] = RewardToken({token: destUsdc, rate: FACTORY.RATE_2(), flat: 0});

        Reward memory reward = Reward({
            deadline: type(uint64).max,
            keeper: depositor,
            prover: FACTORY.STREAMING_FLASH_POLICY(),
            tokens: rw,
            hooks: ""
        });

        intent = Intent({
            protocolVersion: FACTORY.PROTOCOL_VERSION(),
            source: destChain,
            destination: destChain,
            route: route,
            reward: reward
        });
    }

    /// @notice Intent 1: the source-chain CCTP-burn pool (same-chain on block.chainid).
    function _buildIntent1(
        address account2
    ) internal view returns (Intent memory intent) {
        address sourceToken = FACTORY.SOURCE_TOKEN();
        uint64 srcChain = uint64(block.chainid);

        TokenAmount[] memory mo = new TokenAmount[](1);
        mo[0] = TokenAmount({token: sourceToken, amount: FACTORY.MIN_SLICE_1()});

        Route memory route = Route({
            salt: _saltForEpoch(),
            deadline: type(uint64).max,
            portal: FACTORY.PORTAL_ADDRESS(),
            keeper: depositor,
            runtime: FACTORY.CCTP_BURN_RUNTIME(),
            // CONFIG ONLY: (token, messenger, destinationDomain, mintRecipient=account2, maxFeeBps).
            payload: abi.encode(
                sourceToken,
                FACTORY.CCTP_TOKEN_MESSENGER(),
                FACTORY.DESTINATION_DOMAIN(),
                bytes32(uint256(uint160(account2))),
                FACTORY.MAX_FEE_BPS()
            ),
            minTokens: mo
        });

        RewardToken[] memory rw = new RewardToken[](1);
        rw[0] = RewardToken({token: sourceToken, rate: FACTORY.RATE_1(), flat: 0});

        Reward memory reward = Reward({
            deadline: type(uint64).max,
            keeper: depositor,
            prover: FACTORY.STREAMING_FLASH_POLICY(),
            tokens: rw,
            hooks: ""
        });

        intent = Intent({
            protocolVersion: FACTORY.PROTOCOL_VERSION(),
            source: srcChain,
            destination: srcChain,
            route: route,
            reward: reward
        });
    }

    function _intentHash(
        Intent memory intent
    ) internal pure returns (bytes32) {
        return
            IntentLib.hashIntent(
                intent.protocolVersion,
                intent.source,
                intent.destination,
                keccak256(abi.encode(intent.route)),
                keccak256(abi.encode(intent.reward))
            );
    }
}
