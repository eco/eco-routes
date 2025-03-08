// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IInbox} from "../interfaces/IInbox.sol";
import {IIntentSource} from "../interfaces/IIntentSource.sol";
import {Intent, Call, TokenAmount, Route, Reward} from "../types/Intent.sol";

struct EncodedIntent {
    uint8 sourceChainIndex;
    uint8 destinationChainIndex;
    // Reward token
    uint8 rewardTokenIndex;
    uint48 rewardAmount;
    // Route token
    uint8 routeTokenIndex;
    uint48 routeAmount;
    // Expiry duration
    uint24 expiryDuration;
    // Salt
    bytes8 salt;
}

struct EncodedFulfillment {
    uint8 sourceChainIndex;
    uint8 destinationChainIndex;
    // Reward token
    uint8 routeTokenIndex;
    uint48 routeAmount;
    // Prove type (INSTANT = 0, BATCH = 1)
    uint8 proveType;
    // Claimant
    address claimant;
}

contract IntentCompressor {
    using SafeERC20 for IERC20;

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
        EncodedFulfillment memory encodedFulfillment = decodeFulfillPayload(
            payload
        );

        Route memory route = _constructRoute(
            routeSalt,
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
                    encodedFulfillment.claimant,
                    intentHash,
                    PROVER
                );
        } else {
            return
                INBOX.fulfillHyperInstant(
                    route,
                    rewardHash,
                    encodedFulfillment.claimant,
                    intentHash,
                    PROVER
                );
        }
    }

    function publishTransferIntentAndFund(
        bytes32 payload
    ) external returns (bytes32 intentHash) {
        EncodedIntent memory encodedIntent = decodePublishPayload(payload);
        Intent memory intent = _constructIntent(encodedIntent);

        _fundIntent(intent);

        return INTENT_SOURCE.publishAndFund(intent, false);
    }

    // ======================== Public Functions ========================

    function getChainIds() public pure returns (uint16[6] memory) {
        return [1, 10, 137, 8453, 5000, 42161];
    }

    function getTokens() public pure returns (address[15] memory) {
        return [
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

    function decodePublishPayload(
        bytes32 payload
    ) public pure returns (EncodedIntent memory) {
        return
            EncodedIntent({
                sourceChainIndex: uint8(payload[0]), // uint8
                destinationChainIndex: uint8(payload[1]), // uint8
                rewardTokenIndex: uint8(payload[2]), // uint8
                // Reads bytes 3 to 8 and converts them to uint48
                rewardAmount: uint48(_extractUint(payload, 3, 8)), // uint48
                routeTokenIndex: uint8(payload[9]), // uint8
                // Reads bytes 10 to 15 and converts them to uint48
                routeAmount: uint48(_extractUint(payload, 10, 15)), // uint48
                expiryDuration: uint24(_extractUint(payload, 16, 18)), // uint24
                salt: bytes8(uint64(_extractUint(payload, 17, 24))) // bytes8
            });
    }

    function decodeFulfillPayload(
        bytes32 payload
    ) public pure returns (EncodedFulfillment memory) {
        return
            EncodedFulfillment({
                sourceChainIndex: uint8(payload[0]), // uint8
                destinationChainIndex: uint8(payload[1]), // uint8
                routeTokenIndex: uint8(payload[2]), // uint8
                // Reads bytes 10 to 15 and converts them to uint48
                routeAmount: uint48(_extractUint(payload, 3, 8)), // uint48
                proveType: uint8(payload[9]),
                claimant: address(uint160(_extractUint(payload, 10, 29))) // uint48
            });
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
            encodedIntent.sourceChainIndex,
            encodedIntent.destinationChainIndex,
            encodedIntent.routeTokenIndex,
            encodedIntent.routeAmount
        );

        Reward memory reward = _constructReward(
            encodedIntent.rewardTokenIndex,
            encodedIntent.rewardAmount,
            encodedIntent.expiryDuration
        );

        return Intent({route: route, reward: reward});
    }

    function _constructReward(
        uint8 rewardTokenIndex,
        uint48 rewardAmount,
        uint24 expiryDuration
    ) internal view returns (Reward memory) {
        TokenAmount memory rewardToken = TokenAmount({
            token: getTokens()[rewardTokenIndex],
            amount: rewardAmount
        });

        TokenAmount[] memory rewardTokens;
        rewardTokens[0] = rewardToken;

        return
            Reward({
                nativeValue: 0,
                prover: PROVER,
                creator: msg.sender,
                tokens: rewardTokens,
                deadline: block.timestamp + expiryDuration
            });
    }

    function _constructRoute(
        bytes32 salt,
        uint8 sourceChainIndex,
        uint8 destinationChainIndex,
        uint8 routeTokenIndex,
        uint256 routeAmount
    ) internal view returns (Route memory) {
        address routeTokenTarget = getTokens()[routeTokenIndex];

        Call memory routeCallTransfer = Call({
            target: routeTokenTarget,
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (msg.sender, routeAmount))
        });

        TokenAmount memory routeToken = TokenAmount({
            token: routeTokenTarget,
            amount: routeAmount
        });

        TokenAmount[] memory routeTokens;
        routeTokens[0] = routeToken;

        Call[] memory routeCalls;
        routeCalls[0] = routeCallTransfer;

        return
            Route({
                inbox: address(INBOX),
                salt: salt,
                source: getChainIds()[sourceChainIndex],
                destination: getChainIds()[destinationChainIndex],
                calls: routeCalls,
                tokens: routeTokens
            });
    }

    // ======================== Private Functions ========================

    function _extractUint(
        bytes32 data,
        uint8 start,
        uint8 end
    ) private pure returns (uint256) {
        require(start < end, "range has to be greater than zero");
        require(end <= 32, "Out of bounds");

        uint256 length = end - start + 1;
        uint256 result;
        for (uint8 i = 0; i < length; i++) {
            result |= uint256(uint8(data[start + i])) << ((length - 1 - i) * 8);
        }
        return result;
    }
}
