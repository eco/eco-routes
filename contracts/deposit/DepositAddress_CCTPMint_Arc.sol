// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseDepositAddress} from "./BaseDepositAddress.sol";
import {Portal} from "../Portal.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../types/Intent.sol";
import {DepositFactory_CCTPMint_Arc as DepositFactory} from "./DepositFactory_CCTPMint_Arc.sol";

/**
 * @title DepositAddress_CCTPMint_Arc
 * @notice Minimal proxy contract that constructs two Intent structs for CCTP+Gateway transfers to Arc
 * @dev Creates TWO intents to bridge USDC from source chain to Arc via CCTP, then deposit into Gateway:
 *      Intent 2 (published first): Gateway deposit on Arc — receives CCTP-bridged USDC and deposits into Gateway
 *      Intent 1 (published and funded second): CCTP burn on source chain — burns USDC and mints to Intent 2's vault
 *      Each DepositAddress is specific to one user's destination address.
 *      Deployed via CREATE2 by DepositFactory_CCTPMint_Arc for deterministic addressing.
 *
 * @dev Intent Call Flow:
 *      Intent 1: Solver calls TokenMessengerV2.depositForBurn to burn USDC on source chain via CCTP,
 *                minting to Intent 2's vault on Arc.
 *      Intent 2: Solver approves Gateway for USDC and calls Gateway.depositFor to credit the user.
 */
contract DepositAddress_CCTPMint_Arc is BaseDepositAddress {

    // ============ Constants ============

    /// @notice Scaling factor for converting 6-decimal USDC to 18-decimal native USDC on Arc
    uint256 private constant NATIVE_USDC_SCALING = 1e12;

    // ============ Immutables ============

    /// @notice Reference to the factory that deployed this contract
    DepositFactory private immutable FACTORY;

    // ============ Constructor ============

    /**
     * @notice Sets the factory reference (called by factory during deployment)
     */
    constructor() {
        FACTORY = DepositFactory(msg.sender);
    }

    // ============ Internal Functions ============

    /**
     * @notice Get the factory address that deployed this contract
     * @dev Implementation of abstract function from BaseDepositAddress
     * @return Address of the factory contract
     */
    function _factory() internal view override returns (address) {
        return address(FACTORY);
    }

    /**
     * @notice Get the source token address for this deposit
     * @dev Implementation of abstract function from BaseDepositAddress
     * @return Address of the source token
     */
    function _getSourceToken() internal view override returns (address) {
        (address sourceToken, , , , , , , , , ) = FACTORY.getConfiguration();
        return sourceToken;
    }

    /**
     * @notice Execute variant-specific intent creation logic
     * @dev Creates TWO intents:
     *      1. Gateway deposit intent on Arc (published first to obtain vault address)
     *      2. CCTP burn intent on source chain (funded with deposited USDC, mints to Intent 2's vault)
     * @param amount Amount of tokens to bridge
     * @return intentHash Hash of the CCTP burn intent (Intent 1)
     */
    function _executeIntent(uint256 amount) internal override returns (bytes32 intentHash) {
        // Get configuration from factory
        (
            address sourceToken,
            address portalAddress,
            address proverAddress,
            uint64 deadlineDuration,
            uint32 destinationDomain,
            address cctpTokenMessenger,
            uint64 arcChainId,
            address arcProverAddress,
            address arcUsdc,
            address gatewayAddress
        ) = FACTORY.getConfiguration();

        // Generate unique salt (same for both intents) — nonce ensures uniqueness within the same block
        bytes32 salt = keccak256(
            abi.encodePacked(address(this), destinationAddress, block.timestamp, _currentNonce())
        );

        // Calculate deadline (same for both intents)
        uint64 deadline = uint64(block.timestamp + deadlineDuration);

        // ---- Step 1: Construct and publish Intent 2 (Gateway deposit on Arc) ----
        Intent memory intent2 = _constructGatewayIntent(
            arcChainId,
            portalAddress,
            arcProverAddress,
            arcUsdc,
            gatewayAddress,
            amount,
            salt,
            deadline
        );

        // Publish Intent 2 and get its vault address
        Portal portalContract = Portal(portalAddress);
        (, address vault2) = portalContract.publish(intent2);

        // ---- Step 2: Construct, fund, and publish Intent 1 (CCTP burn on source chain) ----
        Intent memory intent1 = _constructCCTPIntent(
            sourceToken,
            portalAddress,
            proverAddress,
            cctpTokenMessenger,
            destinationDomain,
            vault2,
            amount,
            salt,
            deadline
        );

        // Approve Portal to spend tokens and publish+fund Intent 1
        IERC20(sourceToken).approve(portalAddress, amount);
        (intentHash, ) = portalContract.publishAndFund(intent1, false);

        return intentHash;
    }

    /**
     * @notice Construct the Gateway deposit intent (Intent 2) for Arc chain
     * @dev This intent is fulfilled on Arc: solver approves Gateway for USDC and calls depositFor
     * @param arcChainId Arc chain ID
     * @param portalAddress Portal address (same on all chains)
     * @param arcProverAddress LocalProver address on Arc
     * @param arcUsdc USDC ERC20 address on Arc
     * @param gatewayAddress Gateway contract address on Arc
     * @param amount Amount of USDC (6 decimals)
     * @param salt Unique salt for the intent
     * @param deadline Deadline timestamp for the intent
     * @return intent Complete Intent struct for the Gateway deposit
     */
    function _constructGatewayIntent(
        uint64 arcChainId,
        address portalAddress,
        address arcProverAddress,
        address arcUsdc,
        address gatewayAddress,
        uint256 amount,
        bytes32 salt,
        uint64 deadline
    ) internal view returns (Intent memory intent) {
        // Arc's native token is USDC at 18 decimals. The arcUsdc ERC20 is a 6-decimal wrapper.
        // nativeAmount funds the vault in native USDC (18 decimals), while the route calls
        // (approve and depositFor) interact with the 6-decimal ERC20.
        uint256 nativeAmount = amount * NATIVE_USDC_SCALING;

        // Route tokens: empty (native USDC)
        TokenAmount[] memory routeTokens = new TokenAmount[](0);

        // Route calls: approve Gateway + depositFor (both use 6-decimal arcUsdc amounts)
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: arcUsdc,
            data: abi.encodeWithSignature(
                "approve(address,uint256)",
                gatewayAddress,
                amount
            ),
            value: 0
        });
        calls[1] = Call({
            target: gatewayAddress,
            data: abi.encodeWithSignature(
                "depositFor(address,address,uint256)",
                arcUsdc,
                address(uint160(uint256(destinationAddress))),
                amount
            ),
            value: 0
        });

        // Construct route
        Route memory route = Route({
            salt: salt,
            deadline: deadline,
            portal: portalAddress,
            nativeAmount: nativeAmount,
            tokens: routeTokens,
            calls: calls
        });

        // Reward tokens: empty (native USDC reward)
        TokenAmount[] memory rewardTokens = new TokenAmount[](0);

        // Construct reward
        Reward memory reward = Reward({
            deadline: deadline,
            creator: depositor,
            prover: arcProverAddress,
            nativeAmount: nativeAmount,
            tokens: rewardTokens
        });

        // Combine into Intent
        intent = Intent({
            destination: arcChainId,
            route: route,
            reward: reward
        });
    }

    /**
     * @notice Construct the CCTP burn intent (Intent 1) for source chain
     * @dev This intent is fulfilled locally: solver calls TokenMessengerV2.depositForBurn
     *      to burn USDC and mint to Intent 2's vault on Arc
     * @param sourceToken Source USDC token address
     * @param portalAddress Portal address on source chain
     * @param proverAddress LocalProver address on source chain
     * @param cctpTokenMessenger CCTP TokenMessengerV2 address
     * @param destinationDomain CCTP destination domain ID for Arc
     * @param vault2 Intent 2's vault address (CCTP mintRecipient)
     * @param amount Amount of USDC (6 decimals)
     * @param salt Unique salt for the intent
     * @param deadline Deadline timestamp for the intent
     * @return intent Complete Intent struct for the CCTP burn
     */
    function _constructCCTPIntent(
        address sourceToken,
        address portalAddress,
        address proverAddress,
        address cctpTokenMessenger,
        uint32 destinationDomain,
        address vault2,
        uint256 amount,
        bytes32 salt,
        uint64 deadline
    ) internal view returns (Intent memory intent) {
        // Use current chain ID for local intent
        uint64 destChain = uint64(block.chainid);

        // Route tokens: source USDC
        TokenAmount[] memory routeTokens = new TokenAmount[](1);
        routeTokens[0] = TokenAmount({token: sourceToken, amount: amount});

        // Route calls: approve TokenMessenger + CCTP depositForBurn
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: sourceToken,
            data: abi.encodeWithSignature(
                "approve(address,uint256)",
                cctpTokenMessenger,
                amount
            ),
            value: 0
        });
        calls[1] = Call({
            target: cctpTokenMessenger,
            data: abi.encodeWithSignature(
                "depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)",
                amount,
                destinationDomain,
                bytes32(uint256(uint160(vault2))), // mintRecipient = Intent 2 vault
                sourceToken,
                bytes32(0), // destinationCaller (anyone)
                0, // maxFee (standard = free)
                2000 // minFinalityThreshold (standard)
            ),
            value: 0
        });

        // Construct route
        Route memory route = Route({
            salt: salt,
            deadline: deadline,
            portal: portalAddress,
            nativeAmount: 0,
            tokens: routeTokens,
            calls: calls
        });

        // Reward tokens: source USDC
        TokenAmount[] memory rewardTokens = new TokenAmount[](1);
        rewardTokens[0] = TokenAmount({token: sourceToken, amount: amount});

        // Construct reward
        Reward memory reward = Reward({
            deadline: deadline,
            creator: depositor,
            prover: proverAddress,
            nativeAmount: 0,
            tokens: rewardTokens
        });

        // Combine into Intent
        intent = Intent({
            destination: destChain,
            route: route,
            reward: reward
        });
    }
}
