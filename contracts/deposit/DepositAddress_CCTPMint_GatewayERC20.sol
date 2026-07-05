// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseDepositAddress} from "./BaseDepositAddress.sol";
import {Portal} from "../Portal.sol";
import {Intent, Route, Reward, RewardToken, TokenAmount} from "../types/Intent.sol";
import {Call} from "../interfaces/IRuntime.sol";
import {DepositFactory_CCTPMint_GatewayERC20 as DepositFactory} from "./DepositFactory_CCTPMint_GatewayERC20.sol";

/**
 * @title DepositAddress_CCTPMint_GatewayERC20
 * @notice Minimal proxy contract that constructs two Intent structs for CCTP+Gateway transfers to ERC20 destinations
 * @dev Creates TWO intents to bridge USDC from source chain to a destination via CCTP, then deposit into Gateway:
 *      Intent 2 (published first): Gateway deposit on destination — receives CCTP-bridged USDC and deposits into Gateway
 *      Intent 1 (published and funded second): CCTP burn on source chain — burns USDC and mints to Intent 2's account
 *      Each DepositAddress is specific to one user's destination address.
 *      Deployed via CREATE2 by DepositFactory_CCTPMint_GatewayERC20 for deterministic addressing.
 *      Unlike the Arc variant, USDC is a standard ERC20 on the destination (no decimal scaling needed).
 *
 * @dev Intent Call Flow:
 *      Intent 1: Solver calls TokenMessengerV2.depositForBurn to burn USDC on source chain via CCTP,
 *                minting to Intent 2's account on the destination.
 *      Intent 2: Solver approves Gateway for USDC and calls Gateway.depositFor to credit the user.
 */
contract DepositAddress_CCTPMint_GatewayERC20 is BaseDepositAddress {

    // ============ Constants ============

    /// @notice Denominator for fee basis point calculations
    uint256 private constant FEE_DENOMINATOR = 100_000;

    // ============ Immutables ============

    /// @notice Reference to the factory that deployed this contract
    DepositFactory private immutable FACTORY;

    // ============ Errors ============

    /// @notice Reverted when the deposited balance is at or below the configured Eco-protocol flat fee
    error AmountBelowFlatFee();

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
        (address sourceToken, , , , , , , , , , , ) = FACTORY.getConfiguration();
        return sourceToken;
    }

    /**
     * @notice Execute variant-specific intent creation logic
     * @dev Creates TWO intents:
     *      1. Gateway deposit intent on destination (published first to obtain account address)
     *      2. CCTP burn intent on source chain (funded with deposited USDC, mints to Intent 2's account)
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
            uint64 destinationChainId,
            address destinationProverAddress,
            address destinationUsdc,
            address gatewayAddress,
            uint256 maxFeeBps,
            uint256 flatFee
        ) = FACTORY.getConfiguration();

        // Generate unique salt (same for both intents)
        bytes32 salt = keccak256(
            abi.encodePacked(address(this), destinationAddress, block.timestamp)
        );

        // Calculate deadline (same for both intents)
        uint64 deadline = uint64(block.timestamp + deadlineDuration);

        // Apply Eco-protocol flat fee on intent1 + compute CCTP maxFee/netAmount in one helper.
        // routeAmount = amount - flatFee  (intent1's route + CCTP burn input)
        // netAmount   = routeAmount - maxFee (intent2's reward and route; what arrives post-CCTP)
        (uint256 routeAmount, uint256 maxFee, uint256 netAmount) =
            _computeFees(amount, flatFee, maxFeeBps);

        // ---- Step 1: Construct and publish Intent 2 (Gateway deposit on destination) ----
        // Hoisted into a helper so `_executeIntent` keeps its local-variable count below the
        // 16-stack-slot Yul limit imposed by the 12-field config + fee locals.
        Portal portalContract = Portal(portalAddress);
        address account2 = _publishGatewayIntent(
            portalContract,
            destinationChainId,
            portalAddress,
            destinationProverAddress,
            destinationUsdc,
            gatewayAddress,
            netAmount,
            salt,
            deadline
        );

        // ---- Step 2: Construct, fund, and publish Intent 1 (CCTP burn on source chain) ----
        // Intent 1 reward equals `amount` (full deposited balance, pulled by Portal during publishAndFund),
        // while the route obligation drops by `flatFee` so the solver's bridging input is `routeAmount`.
        Intent memory intent1 = _constructCCTPIntent(
            sourceToken,
            portalAddress,
            proverAddress,
            cctpTokenMessenger,
            destinationDomain,
            account2,
            amount,
            routeAmount,
            maxFee,
            salt,
            deadline
        );

        // Approve Portal to spend the full reward amount; Portal pulls reward tokens during publishAndFund
        IERC20(sourceToken).approve(portalAddress, amount);
        (intentHash, ) = portalContract.publishAndFund(intent1, false);

        return intentHash;
    }

    /**
     * @notice Compute the flat-fee-adjusted route amount plus CCTP maxFee in a single helper
     * @dev Reverts with `AmountBelowFlatFee` if `amount <= flatFee`.
     *      `maxFee` rounds up so the user never overpays Circle's CCTP fast-deposit fee.
     * @param amount Full deposit amount
     * @param flatFee Eco-protocol flat fee subtracted from intent1's route
     * @param maxFeeBps CCTP fast-deposit fee in basis points (denominator: FEE_DENOMINATOR)
     * @return routeAmount amount - flatFee (intent1's route amount, also the CCTP burn input)
     * @return maxFee CCTP fast-deposit fee, computed on routeAmount, rounded up
     * @return netAmount routeAmount - maxFee (intent2's reward and route amount; what arrives post-CCTP)
     */
    function _computeFees(
        uint256 amount,
        uint256 flatFee,
        uint256 maxFeeBps
    )
        private
        pure
        returns (uint256 routeAmount, uint256 maxFee, uint256 netAmount)
    {
        if (amount <= flatFee) revert AmountBelowFlatFee();
        routeAmount = amount - flatFee;
        maxFee = (routeAmount * maxFeeBps + FEE_DENOMINATOR - 1) / FEE_DENOMINATOR;
        netAmount = routeAmount - maxFee;
    }

    /**
     * @notice Construct Intent 2 (Gateway deposit on destination) and publish it via the Portal
     * @dev Returning only the account address keeps `_executeIntent`'s local-variable count low
     *      (12 config fields + fee locals would otherwise tip the 16-slot Yul limit).
     * @param netAmount Intent2 reward and route amount (= routeAmount - maxFee, post-CCTP)
     */
    function _publishGatewayIntent(
        Portal portalContract,
        uint64 destinationChainId,
        address portalAddress,
        address destinationProverAddress,
        address destinationUsdc,
        address gatewayAddress,
        uint256 netAmount,
        bytes32 salt,
        uint64 deadline
    ) private returns (address account2) {
        Intent memory intent2 = _constructGatewayIntent(
            destinationChainId,
            portalAddress,
            destinationProverAddress,
            destinationUsdc,
            gatewayAddress,
            netAmount,
            salt,
            deadline
        );
        (, account2) = portalContract.publish(intent2);
    }

    /**
     * @notice Construct the Gateway deposit intent (Intent 2) for destination chain
     * @dev This intent is fulfilled on the destination: solver approves Gateway for USDC and calls depositFor.
     *      Unlike the Arc variant, USDC is a standard ERC20 on the destination so no decimal scaling is needed.
     *      Intent2 reward and route are symmetric (both equal `netAmount`); the flat fee is taken on intent1 only.
     * @param destinationChainId Destination chain ID
     * @param portalAddress Portal address (same on all chains)
     * @param destinationProverAddress LocalPolicy address on destination chain
     * @param destinationUsdc USDC ERC20 address on destination chain
     * @param gatewayAddress Gateway contract address on destination chain
     * @param netAmount Reward and route amount (= routeAmount - CCTP maxFee)
     * @param salt Unique salt for the intent
     * @param deadline Deadline timestamp for the intent
     * @return intent Complete Intent struct for the Gateway deposit
     */
    function _constructGatewayIntent(
        uint64 destinationChainId,
        address portalAddress,
        address destinationProverAddress,
        address destinationUsdc,
        address gatewayAddress,
        uint256 netAmount,
        bytes32 salt,
        uint64 deadline
    ) internal view returns (Intent memory intent) {
        // Solver input floor: ERC20 USDC on destination the solver provides into execution.
        TokenAmount[] memory minTokens = new TokenAmount[](1);
        minTokens[0] = TokenAmount({token: destinationUsdc, amount: netAmount});

        // Route calls: approve Gateway + depositFor (both denominated in netAmount)
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: destinationUsdc,
            data: abi.encodeWithSignature(
                "approve(address,uint256)",
                gatewayAddress,
                netAmount
            ),
            value: 0
        });
        calls[1] = Call({
            target: gatewayAddress,
            data: abi.encodeWithSignature(
                "depositFor(address,address,uint256)",
                destinationUsdc,
                address(uint160(uint256(destinationAddress))),
                netAmount
            ),
            value: 0
        });

        // Construct route: delivery is via the Gateway call; the calls run in the destination Account via
        // the default MulticallRuntime (payload == abi.encode(Call[])) and the ERC20 input funds it.
        Route memory route = Route({
            salt: salt,
            deadline: deadline,
            portal: portalAddress,
            keeper: depositor,
            runtime: FACTORY.MULTICALL_RUNTIME(),
            payload: abi.encode(calls),
            minTokens: minTokens
        });

        // Reward: destination USDC as a single flat leg (rate 0; solver collects this)
        RewardToken[] memory rewardTokens = new RewardToken[](1);
        rewardTokens[0] = RewardToken({
            token: destinationUsdc,
            rate: 0,
            flat: netAmount
        });

        // Construct reward
        Reward memory reward = Reward({
            deadline: deadline,
            keeper: depositor,
            prover: destinationProverAddress,
            tokens: rewardTokens,
            hooks: ""
        });

        // Combine into Intent. Published on this (source) chain; fulfilled on the destination.
        intent = Intent({
            source: uint64(block.chainid),
            destination: destinationChainId,
            route: route,
            reward: reward
        });
    }

    /**
     * @notice Construct the CCTP burn intent (Intent 1) for source chain
     * @dev This intent is fulfilled locally: solver calls TokenMessengerV2.depositForBurn
     *      to burn USDC and mint to Intent 2's account on the destination.
     *      `rewardAmount` and `routeAmount` differ by the Eco-protocol `flatFee`:
     *      the Portal pulls `rewardAmount` from this contract during publishAndFund (solver collects it),
     *      while the solver bridges only `routeAmount` via CCTP. The delta is solver profit.
     * @param sourceToken Source USDC token address
     * @param portalAddress Portal address on source chain
     * @param proverAddress LocalPolicy address on source chain
     * @param cctpTokenMessenger CCTP TokenMessengerV2 address
     * @param destinationDomain CCTP destination domain ID
     * @param account2 Intent 2's account address (CCTP mintRecipient)
     * @param rewardAmount Amount the Portal pulls from this contract as the intent reward (full deposit)
     * @param routeAmount Amount the solver bridges via CCTP (rewardAmount - flatFee)
     * @param maxFee Maximum CCTP fast-deposit fee (deducted on destination, computed on routeAmount)
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
        address account2,
        uint256 rewardAmount,
        uint256 routeAmount,
        uint256 maxFee,
        bytes32 salt,
        uint64 deadline
    ) internal view returns (Intent memory intent) {
        // Use current chain ID for local intent
        uint64 destChain = uint64(block.chainid);

        // Solver input floor: source USDC (solver's bridging obligation, post-flatFee).
        TokenAmount[] memory minTokens = new TokenAmount[](1);
        minTokens[0] = TokenAmount({token: sourceToken, amount: routeAmount});

        // Route calls: approve TokenMessenger + CCTP depositForBurn (both denominated in routeAmount)
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: sourceToken,
            data: abi.encodeWithSignature(
                "approve(address,uint256)",
                cctpTokenMessenger,
                routeAmount
            ),
            value: 0
        });
        calls[1] = Call({
            target: cctpTokenMessenger,
            data: abi.encodeWithSignature(
                "depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)",
                routeAmount,
                destinationDomain,
                bytes32(uint256(uint160(account2))), // mintRecipient = Intent 2 account
                sourceToken,
                bytes32(0), // destinationCaller (anyone)
                maxFee, // maxFee for CCTP fast-deposit (computed on routeAmount)
                0 // minFinalityThreshold (fast finality)
            ),
            value: 0
        });

        // Construct route (CCTP burn on source; the calls consume the full source-USDC input). The calls
        // run in the destination Account via the default MulticallRuntime (payload == abi.encode(Call[])).
        Route memory route = Route({
            salt: salt,
            deadline: deadline,
            portal: portalAddress,
            keeper: depositor,
            runtime: FACTORY.MULTICALL_RUNTIME(),
            payload: abi.encode(calls),
            minTokens: minTokens
        });

        // Reward: source USDC as a single flat leg (rate 0; full deposit, solver collects from Portal)
        RewardToken[] memory rewardTokens = new RewardToken[](1);
        rewardTokens[0] = RewardToken({
            token: sourceToken,
            rate: 0,
            flat: rewardAmount
        });

        // Construct reward
        Reward memory reward = Reward({
            deadline: deadline,
            keeper: depositor,
            prover: proverAddress,
            tokens: rewardTokens,
            hooks: ""
        });

        // Combine into Intent. CCTP burn is fulfilled locally on the source chain (source == dest).
        intent = Intent({
            source: uint64(block.chainid),
            destination: destChain,
            route: route,
            reward: reward
        });
    }
}
