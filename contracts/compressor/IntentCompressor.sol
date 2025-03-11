// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IInbox} from "../interfaces/IInbox.sol";
import {IIntentSource} from "../interfaces/IIntentSource.sol";
import {Intent, Call, TokenAmount, Route, Reward} from "../types/Intent.sol";
import {EncodedIntent, EncodedFulfillment, IntentPacking} from "./IntentEncoderLib.sol";

contract IntentCompressor {
    using SafeERC20 for IERC20;
    using IntentPacking for bytes32;

    /**
     * @notice Thrown when the vault has insufficient token allowance for reward funding
     * @param token The token address
     * @param spender The spender address
     * @param amount The amount of tokens required
     */
    error InsufficientTokenAllowance(
        address token,
        address spender,
        uint256 amount
    );

    address public immutable PROVER;
    IInbox public immutable INBOX;
    IIntentSource public immutable INTENT_SOURCE;

    constructor(address _intentSource, address _inbox, address _prover) {
        INBOX = IInbox(_inbox);
        INTENT_SOURCE = IIntentSource(_intentSource);
        PROVER = _prover;
    }

    function fulfill(
        bytes32 payload,
        bytes32 rewardHash,
        bytes32 routeSalt
    ) external returns (bytes[] memory) {
        // TODO: Validate it can only be called using DELEGATECALL

        EncodedFulfillment memory encodedFulfillment = payload
            .decodeFulfillPayload();

        Route memory route = _constructRoute(
            routeSalt,
            encodedFulfillment.recipient,
            encodedFulfillment.sourceChainIndex,
            encodedFulfillment.destinationChainIndex,
            encodedFulfillment.routeTokenIndex,
            encodedFulfillment.routeAmount
        );

        bytes32 routeHash = keccak256(abi.encode(route));
        bytes32 intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));

        require(
            route.tokens.length == 1,
            "Cannot fulfill intent multiple tokens"
        );

        // Approve route token
        TokenAmount memory routeToken = route.tokens[0];
        IERC20(routeToken.token).approve(address(INBOX), routeToken.amount);

        if (encodedFulfillment.proveType == 1) {
            return
                INBOX.fulfillHyperBatched(
                    route,
                    rewardHash,
                    address(this),
                    intentHash,
                    PROVER
                );
        } else {
            return
                INBOX.fulfillHyperInstant(
                    route,
                    rewardHash,
                    address(this),
                    intentHash,
                    PROVER
                );
        }
    }

    function publishTransferIntentAndFund(
        bytes32 payload
    ) external returns (bytes32 intentHash) {
        EncodedIntent memory encodedIntent = payload.decodePublishPayload();
        Intent memory intent = _constructIntent(encodedIntent);

        _fundIntent(intent);

        return INTENT_SOURCE.publishAndFund(intent, false);
    }

    // ======================== Public Functions ========================

    function getChainIds() public pure returns (uint16[6] memory) {
        return [1, 10, 137, 8453, 5000, 42161];
    }

    function getTokens() public pure returns (address[16] memory) {
        return [
            0x0000000000000000000000000000000000000000, // Native Token
            // Ethereum
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, // USDC
            0xdAC17F958D2ee523a2206206994597C13D831ec7, // USDT
            // Optimism
            0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85, // USDC
            0x94b008aA00579c1307B0EF2c499aD98a8ce58e58, // USDT
            0x7F5c764cBc14f9669B88837ca1490cCa17c31607, // USDC.e
            // Polygon
            0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359, // USDC
            0xc2132D05D31c914a87C6611C10748AEb04B58e8F, // USDT
            0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174, // USDC.e
            // Base
            0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, // USDC
            0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA, // USDbC
            // Mantle
            0x201EBa5CC46D216Ce6DC03F6a759e8E766e956aE, // USDT
            0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9, // USDC
            // Arbitrum
            0xaf88d065e77c8cC2239327C5EDb3A432268e5831, // USDC
            0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8, // USDC.e
            0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9 // USDT
        ];
    }

    // ======================== Internal Functions ========================

    function _fundIntent(Intent memory intent) internal {
        address funder = msg.sender;
        TokenAmount[] memory tokens = intent.reward.tokens;

        // Get vault address from intent
        address vault = INTENT_SOURCE.intentVaultAddress(intent);

        // Cache tokens length
        uint256 rewardsLength = tokens.length;

        // Iterate through each token in the reward structure
        for (uint256 i; i < rewardsLength; ++i) {
            // Get token address and required amount for current reward
            address token = tokens[i].token;
            uint256 amount = tokens[i].amount;
            uint256 balance = IERC20(token).balanceOf(vault);

            // Only proceed if vault needs more tokens and we have permission to transfer them
            if (amount > balance) {
                // Calculate how many more tokens the vault needs to be fully funded
                uint256 remainingAmount = amount - balance;

                // Check how many tokens this contract is allowed to transfer from funding source
                uint256 allowance = IERC20(token).allowance(
                    funder,
                    address(this)
                );

                // Check if allowance is sufficient to fund intent
                if (allowance < remainingAmount) {
                    revert InsufficientTokenAllowance(
                        token,
                        funder,
                        remainingAmount
                    );
                }

                // Transfer tokens from funding source to vault using safe transfer
                IERC20(token).safeTransferFrom(funder, vault, remainingAmount);
            }
        }
    }

    function _constructIntent(
        EncodedIntent memory encodedIntent
    ) internal view returns (Intent memory) {
        Route memory route = _constructRoute(
            bytes32(encodedIntent.salt),
            msg.sender,
            encodedIntent.sourceChainIndex,
            encodedIntent.destinationChainIndex,
            encodedIntent.routeTokenIndex,
            encodedIntent.routeAmount
        );

        Reward memory reward = _constructReward(
            encodedIntent.rewardTokenIndex,
            encodedIntent.rewardAmount,
            encodedIntent.expiresIn
        );

        return Intent({route: route, reward: reward});
    }

    function _constructReward(
        uint8 rewardTokenIndex,
        uint48 rewardAmount,
        uint24 expiresIn
    ) internal view returns (Reward memory) {
        TokenAmount[] memory rewardTokens;

        if (rewardTokenIndex != 0) {
            TokenAmount memory rewardToken = TokenAmount({
                token: _getToken(rewardTokenIndex),
                amount: rewardAmount
            });

            rewardTokens = new TokenAmount[](1);
            rewardTokens[0] = rewardToken;
        }

        return
            Reward({
                prover: PROVER,
                nativeValue: msg.value,
                creator: msg.sender,
                tokens: rewardTokens,
                deadline: block.timestamp + expiresIn
            });
    }

    function _constructRoute(
        bytes32 salt,
        address recipient,
        uint8 sourceChainIndex,
        uint8 destinationChainIndex,
        uint8 routeTokenIndex,
        uint256 routeAmount
    ) internal view returns (Route memory) {
        Call[] memory routeCalls;
        TokenAmount[] memory routeTokens;

        bool isNativeTransfer = routeTokenIndex == 0;
        bool hasEthTransfer = msg.value > 0;

        if (!isNativeTransfer) {
            address routeTokenTarget = _getToken(routeTokenIndex);

            // Create the ERC20 transfer call
            Call memory routeCallTransfer = Call({
                target: routeTokenTarget,
                value: 0,
                data: abi.encodeCall(IERC20.transfer, (recipient, routeAmount))
            });

            // Set token transfer details
            routeTokens = new TokenAmount[](1);
            routeTokens[0] = TokenAmount({
                token: routeTokenTarget,
                amount: routeAmount
            });

            // Allocate call array with proper size
            uint8 callsCount = hasEthTransfer ? 2 : 1;
            routeCalls = new Call[](callsCount);
            routeCalls[0] = routeCallTransfer;
        } else {
            routeTokens = new TokenAmount[](0); // declare an empty array
            routeCalls = new Call[](hasEthTransfer ? 1 : 0); // Allocate if ETH is sent
        }

        // Handle native token transfer if applicable
        if (hasEthTransfer) {
            routeCalls[routeCalls.length - 1] = Call({
                target: msg.sender,
                value: msg.value,
                data: new bytes(0)
            });
        }

        return
            Route({
                inbox: address(INBOX),
                salt: salt,
                source: _getChainId(sourceChainIndex),
                destination: _getChainId(destinationChainIndex),
                calls: routeCalls,
                tokens: routeTokens
            });
    }

    // ======================== Private Functions ========================

    function _getChainId(uint256 index) private pure returns (uint256) {
        require(index <= 5, "Chain id index out-of-bounds");
        return getChainIds()[index];
    }

    function _getToken(uint256 index) private pure returns (address) {
        require(index <= 15, "Token index out-of-bounds");
        return getTokens()[index];
    }
}
