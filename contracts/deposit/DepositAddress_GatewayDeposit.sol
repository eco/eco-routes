// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseDepositAddress} from "./BaseDepositAddress.sol";
import {Portal} from "../Portal.sol";
import {Intent, Route, Reward, TokenAmount, Call} from "../types/Intent.sol";
import {DepositFactory_GatewayDeposit as DepositFactory} from "./DepositFactory_GatewayDeposit.sol";

/**
 * @title DepositAddress_GatewayDeposit
 * @notice Minimal proxy contract that constructs Intent structs for Gateway deposits
 * @dev Each DepositAddress is specific to one user's destination address
 *      Deployed via CREATE2 by DepositFactory_GatewayDeposit for deterministic addressing
 *      Uses standard Intent/Route/Reward structs instead of Borsh-encoded bytes
 */
contract DepositAddress_GatewayDeposit is BaseDepositAddress {

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
        (, address sourceToken, , , , , , ) = FACTORY.getConfiguration();
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
            uint64 destChain,
            address sourceToken,
            address destinationToken,
            address portal,
            address prover,
            address destPortal,
            address gateway,
            uint64 deadlineDuration
        ) = FACTORY.getConfiguration();

        // Construct Intent struct
        Intent memory intent = _constructIntent(
            destChain,
            sourceToken,
            destinationToken,
            destPortal,
            prover,
            gateway,
            amount,
            deadlineDuration,
            depositor
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
     * @notice Construct complete Intent struct for EVM destination
     * @param destChain Destination chain ID
     * @param sourceToken Source token address
     * @param destinationToken Destination token address on destination chain
     * @param destPortal Portal address on destination chain
     * @param prover Prover contract address
     * @param gateway Gateway contract address on destination chain
     * @param amount Amount of tokens to transfer
     * @param deadlineDuration Deadline duration in seconds
     * @param depositorAddr Depositor address for Gateway call
     * @return intent Complete Intent struct ready for publishing
     */
    function _constructIntent(
        uint64 destChain,
        address sourceToken,
        address destinationToken,
        address destPortal,
        address prover,
        address gateway,
        uint256 amount,
        uint64 deadlineDuration,
        address depositorAddr
    ) internal view returns (Intent memory intent) {
        // Construct Route
        Route memory route = _constructRoute(
            destinationToken,
            destPortal,
            gateway,
            amount,
            deadlineDuration,
            depositorAddr
        );

        // Construct Reward
        Reward memory reward = _constructReward(
            sourceToken,
            prover,
            amount,
            deadlineDuration,
            depositorAddr
        );

        // Combine into Intent
        intent = Intent({destination: destChain, route: route, reward: reward});
    }

    /**
     * @notice Construct Route struct with Gateway depositFor call
     * @param destinationToken Token address on destination chain
     * @param destPortal Portal address on destination chain
     * @param gateway Gateway contract address on destination chain
     * @param amount Amount of tokens to transfer
     * @param deadlineDuration Deadline duration in seconds
     * @param depositorAddr Depositor address for Gateway call
     * @return route Route struct with Gateway depositFor call
     */
    function _constructRoute(
        address destinationToken,
        address destPortal,
        address gateway,
        uint256 amount,
        uint64 deadlineDuration,
        address depositorAddr
    ) internal view returns (Route memory route) {
        // Generate unique salt
        bytes32 salt = keccak256(
            abi.encodePacked(address(this), destinationAddress, block.timestamp)
        );

        // Calculate deadline
        uint64 deadline = uint64(block.timestamp + deadlineDuration);

        // Construct token array
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: destinationToken, amount: amount});

        // Construct Gateway depositFor call
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: gateway,
            data: abi.encodeWithSignature(
                "depositFor(address,address,uint256)",
                destinationToken,
                depositorAddr,
                amount
            ),
            value: 0
        });

        // Construct route
        route = Route({
            salt: salt,
            deadline: deadline,
            portal: destPortal,
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
     * @param depositorAddr Depositor address to receive refunds
     * @return reward Reward struct with escrowed source tokens
     */
    function _constructReward(
        address sourceToken,
        address prover,
        uint256 amount,
        uint64 deadlineDuration,
        address depositorAddr
    ) internal view returns (Reward memory reward) {
        // Calculate deadline
        uint64 deadline = uint64(block.timestamp + deadlineDuration);

        // Construct reward token array
        TokenAmount[] memory tokens = new TokenAmount[](1);
        tokens[0] = TokenAmount({token: sourceToken, amount: amount});

        // Construct reward
        reward = Reward({
            deadline: deadline,
            creator: depositorAddr, // Depositor is creator (matches Solana implementation)
            prover: prover,
            nativeAmount: 0,
            tokens: tokens
        });
    }
}
