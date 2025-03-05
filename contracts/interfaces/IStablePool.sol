// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Route, TokenAmount} from "../types/Intent.sol";

interface IStablePool {
    struct WithdrawalQueueEntry {
        address user;
        uint96 amount;
    }

    event WhitelistUpdated(address[] _newWhitelist);
    event TokenThresholdsChanged(TokenAmount[] _newThresholds);

    event TokenThresholdChanged(address indexed token, uint256 threshold);
    event Deposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event Withdrawn(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    event AddedToWithdrawalQueue(
        address indexed user,
        WithdrawalQueueEntry entry
    );

    // this is basically an error state
    event WithdrawalQueueThresholdReached(address token);

    // Custom Errors for Gas Efficiency
    error InvalidToken();
    error InvalidAmount();
    error InsufficientTokenBalance(
        address _token,
        uint256 _balance,
        uint256 _needed
    );
    error TransferFailed();

    error InvalidCaller(address _caller, address _expectedCaller);
    error LitPaused();
    error InvalidSignature(bytes32 _hash, bytes _signature);
    error InvalidTokensHash(bytes32 _expectedHash);

    function updateThreshold(address token, uint256 allowed) external;
    function deposit(address token, uint256 amount) external;
    function withdraw(address token, uint256 amount) external;
    function getBalance(address user) external view returns (uint256);
    function accessLiquidity(
        Route calldata _route,
        bytes32 _rewardhash,
        bytes32 _intentHash,
        address _prover,
        bytes memory _signature
    ) external payable;
}
