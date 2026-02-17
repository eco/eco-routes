// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseDepositAddress} from "./BaseDepositAddress.sol";
import {Portal} from "../Portal.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../types/Intent.sol";
import {DepositFactory_CCTPMint_Arc as DepositFactory} from "./DepositFactory_CCTPMint_Arc.sol";

/**
 * @title DepositAddress_CCTPMint_Arc
 * @notice Minimal proxy contract that constructs Intent structs for CCTP transfers to Arc
 * @dev Creates LOCAL intents (same-chain fulfillment).
 *      Each DepositAddress is specific to one user's destination address.
 *      Deployed via CREATE2 by DepositFactory_CCTPMint_Arc for deterministic addressing.
 *
 * @dev Intent Call Flow:
 *      When a solver fulfills the intent, it executes:
 *      `TokenMessenger.depositForBurn(uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken)`
 *
 *      This burns USDC tokens on the current chain via CCTP and initiates a cross-chain
 *      message to mint tokens on the destination domain (Arc), with the mintRecipient
 *      receiving the minted tokens.
 */
contract DepositAddress_CCTPMint_Arc is BaseDepositAddress {

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
        (address sourceToken, , , , , , ) = FACTORY.getConfiguration();
        return sourceToken;
    }

    /**
     * @notice Execute variant-specific intent creation logic
     * @dev Implementation of abstract function from BaseDepositAddress
     * @param amount Amount of tokens to bridge
     * @return intentHash Hash of the created intent
     */
    function _executeIntent(uint256 amount) internal override returns (bytes32 intentHash) {
        // Get configuration from factory
        (
            address sourceToken,
            address destinationToken,
            address portal,
            address prover,
            uint64 deadlineDuration,
            uint32 destinationDomain,
            address cctpTokenMessenger
        ) = FACTORY.getConfiguration();

        // Use current chain ID for local intent
        uint64 destChain = uint64(block.chainid);

        // Construct Intent struct
        Intent memory intent = _constructIntent(
            destChain,
            sourceToken,
            destinationToken,
            portal,
            prover,
            amount,
            deadlineDuration,
            destinationDomain,
            cctpTokenMessenger
        );

        // Approve Portal to spend tokens
        IERC20(sourceToken).approve(portal, amount);

        // Call Portal.publishAndFund with Intent struct
        Portal portalContract = Portal(portal);
        address vault;
        (intentHash, vault) = portalContract.publishAndFund(
            intent,
            false // allowPartial = false
        );

        return intentHash;
    }

    /**
     * @notice Construct complete Intent struct
     * @param destChain Destination chain ID
     * @param sourceToken Source token address
     * @param destinationToken Destination token address
     * @param portal Portal address
     * @param prover Prover contract address
     * @param amount Amount of tokens to transfer
     * @param deadlineDuration Deadline duration in seconds
     * @param destinationDomain CCTP destination domain ID
     * @param cctpTokenMessenger CCTP TokenMessenger contract address
     * @return intent Complete Intent struct ready for publishing
     */
    function _constructIntent(
        uint64 destChain,
        address sourceToken,
        address destinationToken,
        address portal,
        address prover,
        uint256 amount,
        uint64 deadlineDuration,
        uint32 destinationDomain,
        address cctpTokenMessenger
    ) internal view returns (Intent memory intent) {
        // Construct Route
        Route memory route = _constructRoute(
            destinationToken,
            portal,
            amount,
            deadlineDuration,
            destinationDomain,
            sourceToken,
            cctpTokenMessenger
        );

        // Construct Reward
        Reward memory reward = _constructReward(
            sourceToken,
            prover,
            amount,
            deadlineDuration
        );

        // Combine into Intent
        intent = Intent({destination: destChain, route: route, reward: reward});
    }

    /**
     * @notice Construct Route struct with CCTP depositForBurn call
     * @param destinationToken Token address on destination chain
     * @param portal Portal address
     * @param amount Amount of tokens to burn and mint
     * @param deadlineDuration Deadline duration in seconds
     * @param destinationDomain CCTP destination domain ID
     * @param sourceToken Source token to burn
     * @param cctpTokenMessenger CCTP TokenMessenger contract address
     * @return route Route struct with CCTP depositForBurn call
     */
    function _constructRoute(
        address destinationToken,
        address portal,
        uint256 amount,
        uint64 deadlineDuration,
        uint32 destinationDomain,
        address sourceToken,
        address cctpTokenMessenger
    ) internal view returns (Route memory route) {
        // Generate unique salt
        bytes32 salt = keccak256(
            abi.encodePacked(address(this), destinationAddress, block.timestamp)
        );

        // Calculate deadline
        uint64 deadline = uint64(block.timestamp + deadlineDuration);

        // Construct token array (for destination chain)
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: destinationToken, amount: amount});

        // destinationAddress is already bytes32 format, use directly as CCTP mintRecipient
        // Construct CCTP depositForBurn call
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: cctpTokenMessenger,
            data: abi.encodeWithSignature(
                "depositForBurn(uint256,uint32,bytes32,address)",
                amount,
                destinationDomain,
                destinationAddress, // Use bytes32 destinationAddress directly as mintRecipient
                sourceToken
            ),
            value: 0
        });

        // Construct route
        route = Route({
            salt: salt,
            deadline: deadline,
            portal: portal,
            nativeAmount: 0,
            tokens: tokens,
            calls: calls
        });
    }

    /**
     * @notice Construct Reward struct for the intent
     * @param sourceToken Source token address
     * @param prover Prover contract address
     * @param amount Amount of tokens as reward
     * @param deadlineDuration Deadline duration in seconds
     * @return reward Reward struct with escrowed source tokens
     */
    function _constructReward(
        address sourceToken,
        address prover,
        uint256 amount,
        uint64 deadlineDuration
    ) internal view returns (Reward memory reward) {
        // Calculate deadline
        uint64 deadline = uint64(block.timestamp + deadlineDuration);

        // Construct reward token array
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: sourceToken, amount: amount});

        // Construct reward
        reward = Reward({
            deadline: deadline,
            creator: depositor, // Depositor is creator (matches Solana implementation)
            prover: prover,
            nativeAmount: 0,
            tokens: tokens
        });
    }
}
