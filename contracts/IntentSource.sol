/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IIntentSource} from "./interfaces/IIntentSource.sol";
import {SimpleProver} from "./interfaces/SimpleProver.sol";
import {Intent, Reward, Route} from "./types/Intent.sol";
import {Semver} from "./libs/Semver.sol";

import {IntentVault} from "./IntentVault.sol";

/**
 * This contract is the source chain portion of the Eco Protocol's intent system.
 *
 * It can be used to create intents as well as withdraw the associated rewards.
 * Its counterpart is the inbox contract that lives on the destination chain.
 * This contract makes a call to the prover contract (on the sourcez chain) in order to verify intent fulfillment.
 */
contract IntentSource is IIntentSource {
    using SafeERC20 for IERC20;

    // stores the intents
    mapping(bytes32 intentHash => address) public claimed;

    address public vaultRefundToken;

    /**
     * @dev counterStart is required to preserve nonce uniqueness in the event IntentSource needs to be redeployed.
     * _counterStart the initial value of the counter
     */
    constructor() {}

    function version() external pure returns (string memory) {
        return Semver.version();
    }

    function getClaimed(bytes32 intentHash) external view returns (address) {
        return claimed[intentHash];
    }

    function getVaultRefundToken() external view returns (address) {
        return vaultRefundToken;
    }

    function getIntentHash(
        Intent calldata intent
    ) public pure returns (bytes32 intentHash, bytes32 routeHash, bytes32 rewardHash) {
        routeHash = keccak256(abi.encode(intent.route));
        rewardHash = keccak256(abi.encode(intent.reward));
        intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));
    }

    function intentVaultAddress(
        Intent calldata intent
    ) public view returns (address) {
        (bytes32 intentHash, bytes32 routeHash,) = getIntentHash(intent);
        return _getIntentVaultAddress(intentHash, routeHash, intent.reward);
    }

    /**
     * @notice Creates an intent to execute instructions on a contract on a supported chain in exchange for a bundle of assets.
     * @dev If a proof ON THE SOURCE CHAIN is not completed by the expiry time, the reward funds will not be redeemable by the solver, REGARDLESS OF WHETHER THE INSTRUCTIONS WERE EXECUTED.
     * The onus of that time management (i.e. how long it takes for data to post to L1, etc.) is on the intent solver.
     * @param intent The intent struct with all the intent params
     * @param fundReward whether to fund the reward or not
     * @return intentHash the hash of the intent
     */
    function publishIntent(Intent calldata intent, bool fundReward) external payable returns (bytes32 intentHash) {
        Route calldata route = intent.route;
        Reward calldata reward = intent.reward;

        uint256 rewardsLength = reward.tokens.length;
        bytes32 routeHash;

        (intentHash, routeHash,) = getIntentHash(intent);

        address vault = _getIntentVaultAddress(intentHash, routeHash, reward);

        if (fundReward) {
            if (_validateIntent(intent, vault)) {
                revert("IntentSource: intent is already funded");
            }
            
            if (reward.nativeValue > 0) {
                require(msg.value >= reward.nativeValue, "IntentSource: insufficient native reward");

                payable(vault).transfer(reward.nativeValue);

                if (msg.value > reward.nativeValue) {
                    payable(msg.sender).transfer(msg.value - reward.nativeValue);
                }
            }

            for (uint256 i = 0; i < rewardsLength; i++) {
                address token = reward.tokens[i].token;
                uint256 amount = reward.tokens[i].amount;

                IERC20(token).safeTransferFrom(msg.sender, vault, amount);
            }
        } else if (block.chainid == intent.route.source) {
            require(_validateIntent(intent, vault), "IntentSource: invalid intent");
        }

        emit IntentCreated(
            intentHash,
            route.nonce,
            route.destination,
            route.inbox,
            route.calls,
            reward.creator,
            reward.prover,
            reward.expiryTime,
            reward.nativeValue,
            reward.tokens
        );
    }

    function validateIntent(
        Intent calldata intent
    ) external view returns (bool) {
        (bytes32 intentHash, bytes32 routeHash,) = getIntentHash(intent);
        address vault = _getIntentVaultAddress(intentHash, routeHash, intent.reward);

        return _validateIntent(intent, vault);
    }

    /**
     * @notice Withdraws the rewards associated with an intent to its claimant
     * @param routeHash The hash of the route of the intent
     * @param reward The reward of the intent
     */
    function withdrawRewards(bytes32 routeHash, Reward calldata reward) public {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));

        address claimant = SimpleProver(reward.prover).provenIntents(
            intentHash
        );

        // Claim the rewards if the intent has not been claimed
        if (claimant != address(0) && claimed[intentHash] == address(0)) {
            claimed[intentHash] = claimant;

            emit Withdrawal(intentHash, claimant);

            new IntentVault{salt: routeHash}(intentHash, reward);

            return;
        }

        if (claimant != address(0) ) {
            revert NothingToWithdraw(intentHash);
        }

        // Refund the rewards if the intent has expired
        if (claimant == address(0) && block.timestamp < reward.expiryTime) {
            revert UnauthorizedWithdrawal(intentHash);
        }

        emit Withdrawal(intentHash, reward.creator);

        new IntentVault{salt: routeHash}(intentHash, reward);
    }

    /**
     * @notice Withdraws a batch of intents that all have the same claimant
     * @param routeHashes The hashes of the routes of the intents
     * @param rewards The rewards of the intents
     */
    function batchWithdraw(bytes32[] calldata routeHashes, Reward[] calldata rewards) external {
        uint256 length = routeHashes.length;
        require(length == rewards.length, "IntentSource: array length mismatch");

        for (uint256 i = 0; i < length; i++) {
            withdrawRewards(routeHashes[i], rewards[i]);
        }
    }

    /**
     * @notice Refunds the rewards associated with an intent to its creator
     * @param routeHash The hash of the route of the intent
     * @param reward The reward of the intent
     * @param token Any specific token that could be wrongly sent to the vault
     */
    function refundIntent(bytes32 routeHash, Reward calldata reward, address token) external {
        bytes32 rewardHash = keccak256(abi.encode(reward));
        bytes32 intentHash = keccak256(abi.encodePacked(routeHash, rewardHash));

        if (claimed[intentHash] == address(0) && block.timestamp < reward.expiryTime) {
            revert UnauthorizedWithdrawal(intentHash);
        }

        if (token == address(0)) {
            token = address(1);
        }

        vaultRefundToken = token;
        new IntentVault{salt: routeHash}(intentHash,reward);


        vaultRefundToken = address(0);

    }

    function _validateIntent(
        Intent calldata intent,
        address vault
    ) internal view returns (bool) {
        Reward calldata reward = intent.reward;
        uint256 rewardsLength = reward.tokens.length;

        if (vault.balance < reward.nativeValue) return false;

        for (uint256 i = 0; i < rewardsLength; i++) {
            address token = reward.tokens[i].token;
            uint256 amount = reward.tokens[i].amount;
            uint256 balance = IERC20(token).balanceOf(vault);

            if (balance < amount) return false;
        }

        return true;
    }


    function _getIntentVaultAddress(
        bytes32 intentHash,
        bytes32 routeHash,
        Reward calldata reward
    ) internal view returns (address) {
        /* Convert a hash which is bytes32 to an address which is 20-byte long
        according to https://docs.soliditylang.org/en/v0.8.9/control-structures.html?highlight=create2#salted-contract-creations-create2 */
        return
            address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            address(this),
                            routeHash,
                            keccak256(
                                abi.encodePacked(
                                    type(IntentVault).creationCode,
                                    abi.encode(intentHash, reward)
                                )
                            )
                        )
                    )
                )
            )
        );
    }

}
