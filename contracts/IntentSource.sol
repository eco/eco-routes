/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/*
 * ░▒▓████████▓▒░▒▓██████▓▒░ ░▒▓██████▓▒░
 * ░▒▓█▓▒░     ░▒▓█▓▒░░▒▓█▓▒░▒▓█▓▒░░▒▓█▓▒░
 * ░▒▓█▓▒░     ░▒▓█▓▒░      ░▒▓█▓▒░░▒▓█▓▒░
 * ░▒▓██████▓▒░░▒▓█▓▒░      ░▒▓█▓▒░░▒▓█▓▒░
 * ░▒▓█▓▒░     ░▒▓█▓▒░      ░▒▓█▓▒░░▒▓█▓▒░
 * ░▒▓█▓▒░     ░▒▓█▓▒░░▒▓█▓▒░▒▓█▓▒░░▒▓█▓▒░
 * ░▒▓████████▓▒░▒▓██████▓▒░ ░▒▓██████▓▒░
 */

import "./interfaces/IIntentSource.sol";
import "./libs/SimpleProver.sol";
import "./types/Intent.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * This contract is the source chain portion of the Eco Protocol's intent system.
 *
 * It can be used to create intents as well as withdraw the associated rewards.
 * Its counterpart is the inbox contract that lives on the destination chain.
 * This contract makes a call to the prover contract (on the sourcez chain) in order to verify intent fulfillment.
 */
contract IntentSource is IIntentSource {
    using SafeERC20 for IERC20;

    // intent creation counter
    uint256 public counter;

    // stores the intents
    mapping(bytes32 intentHash => Intent) public intents;

    /**
     * @dev counterStart is required to preserve nonce uniqueness in the event IntentSource needs to be redeployed.
     * _counterStart the initial value of the counter
     */
    constructor(uint256 _counterStart) {
        counter = _counterStart;
    }

    function version() external pure returns (string memory) {
        return Semver.version();
    }
    /**
     * @notice Creates an intent to execute instructions on a contract on a supported chain in exchange for a bundle of assets.
     * @dev If a proof ON THE SOURCE CHAIN is not completed by the expiry time, the reward funds will not be redeemable by the solver, REGARDLESS OF WHETHER THE INSTRUCTIONS WERE EXECUTED.
     * The onus of that time management (i.e. how long it takes for data to post to L1, etc.) is on the intent solver.
     * @dev The inbox contract on the destination chain will be the msg.sender for the instructions that are executed.
     * @param _destinationChainID the destination chain
     * @param _inbox the inbox contract on the destination chain
     * @param _targets the addresses on _destinationChainID at which the instructions need to be executed
     * @param _data the instruction sets to be executed on _targets
     * @param _rewardTokens the addresses of reward tokens
     * @param _rewardAmounts the amounts of reward tokens
     * @param _expiryTime the timestamp at which the intent expires
     * @param _prover the prover against which the intent's status will be checked
     */

    function createIntent(
        uint256 _destinationChainID,
        address _inbox,
        address[] calldata _targets,
        bytes[] calldata _data,
        address[] calldata _rewardTokens,
        uint256[] calldata _rewardAmounts,
        uint256 _expiryTime,
        address _prover
    ) external payable returns (bytes32) {
        uint256 len = _targets.length;
        if (len == 0 || len != _data.length) {
            revert CalldataMismatch();
        }

        len = _rewardTokens.length;
        if (len != _rewardAmounts.length) {
            revert RewardsMismatch();
        }

        uint256 chainID = block.chainid;
        bytes32 _nonce = keccak256(abi.encode(counter, chainID));
        bytes32 intermediateHash = keccak256(
            abi.encode(chainID, _destinationChainID, _targets, _data, _expiryTime, _nonce)
        );
        bytes32 intentHash = keccak256(abi.encode(_inbox, intermediateHash));

        intents[intentHash] = Intent({
            creator: msg.sender,
            destinationChainID: _destinationChainID,
            targets: _targets,
            data: _data,
            rewardTokens: _rewardTokens,
            rewardAmounts: _rewardAmounts,
            expiryTime: _expiryTime,
            isActive: true,
            nonce: _nonce,
            prover: _prover,
            rewardNative: msg.value
        });

        emitIntentCreated(intentHash, intents[intentHash]);
        counter += 1;

        for (uint256 i = 0; i < len; i++) {
            IERC20(_rewardTokens[i]).safeTransferFrom(
                msg.sender,
                address(this),
                _rewardAmounts[i]
            );
        }

        return intentHash;
    }

    function emitIntentCreated(bytes32 _hash, Intent memory _intent) internal {
        //gets around Stack Too Deep
        emit IntentCreated(
            _hash,
            msg.sender,
            _intent.destinationChainID,
            _intent.targets,
            _intent.data,
            _intent.rewardTokens,
            _intent.rewardAmounts,
            _intent.expiryTime,
            _intent.nonce,
            _intent.prover,
            _intent.rewardNative
        );
    }
    /**
     * @notice Withdraws the rewards associated with an intent to its claimant
     * @param _hash the hash of the intent
     */

    function withdrawRewards(bytes32 _hash) external {
        Intent storage intent = intents[_hash];
        address claimant = SimpleProver(intent.prover).provenIntents(_hash);
        address withdrawTo;
        if (intent.isActive) {
            if (claimant != address(0)) {
                withdrawTo = claimant;
            } else {
                if (block.timestamp >= intent.expiryTime) {
                    withdrawTo = intent.creator;
                } else {
                    revert UnauthorizedWithdrawal(_hash);
                }
            }
            intent.isActive = false;
            emit Withdrawal(_hash, withdrawTo);
            uint256 len = intent.rewardTokens.length;
            for (uint256 i = 0; i < len; i++) {
                IERC20(intent.rewardTokens[i]).safeTransfer(
                    withdrawTo,
                    intent.rewardAmounts[i]
                );
            }
            uint256 nativeReward = intent.rewardNative;
            if (nativeReward > 0) {
                (bool success, ) = payable(withdrawTo).call{value: nativeReward}("");
                require(success, "Native transfer failed.");
            }
        } else {
            revert NothingToWithdraw(_hash);
        }
    }
    /**
     * @notice Withdraws a batch of intents that all have the same claimant
     * @param _hashes the array of intent hashes
     * @param _claimant the claimant
     * @dev For best performance, group intents s.t. intents with the same reward token are consecutive. If there are intents with multiple reward tokens, put them at the end. Ideally don't include those kinds of intents here though.
     */

    function batchWithdraw(bytes32[] calldata _hashes, address _claimant) external {
        if (_claimant == address(0)) {
            revert BadClaimant(0x0);
        }
        address erc20;
        uint256 balance;
        uint256 nativeRewards;

        for (uint256 i = 0; i < _hashes.length; i++) {
            bytes32 _hash = _hashes[i];
            Intent storage intent = intents[_hash];
            if (!intent.isActive) {
                revert NothingToWithdraw(_hash);
            }
            address claimant = SimpleProver(intent.prover).provenIntents(_hash);
            if (claimant != _claimant) {
                if (intent.creator != _claimant) {
                    revert BadClaimant(_hash);
                }
                // trying to reclaim rewards for an expired intent
                if (claimant != address(0) || block.timestamp < intent.expiryTime) {
                    // intent is not expired
                    revert UnauthorizedWithdrawal(_hash);
                }
            }
            intent.isActive = false;
            for (uint256 j = 0; j < intent.rewardTokens.length; j++) {
                address newToken = intent.rewardTokens[j];
                if (erc20 == newToken) {
                    balance += intent.rewardAmounts[j];
                } else {
                    safeERC20Transfer(erc20, _claimant, balance);
                    erc20 = newToken;
                    balance = intent.rewardAmounts[j];
                }
            }
            nativeRewards += intent.rewardNative;
            emit Withdrawal(_hash, _claimant);
        }
        safeERC20Transfer(erc20, _claimant, balance);
        if (nativeRewards > 0) {
            (bool success, ) = payable(_claimant).call{value: nativeRewards}("");
            require(success, "Native transfer failed.");
        }
    }

    function safeERC20Transfer(address _token, address _to, uint256 _amount) internal {
        if (_token != address(0)) {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }

    function getIntent(bytes32 identifier) public view returns (Intent memory) {
        return intents[identifier];
    }
}
