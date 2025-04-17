// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {MessageBridgeProver} from "./prover/MessageBridgeProver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IInbox} from "./interfaces/IInbox.sol";
import {Intent, Route, Call, TokenAmount} from "./types/Intent.sol";
import {Semver} from "./libs/Semver.sol";

/**
 * @title Inbox
 * @notice Main entry point for fulfilling intents
 * @dev Validates intent hash authenticity and executes calldata. Enables provers
 * to claim rewards on the source chain by checking the fulfilled mapping
 */
contract Inbox is IInbox, Ownable, Semver {
    using TypeCasts for address;
    using SafeERC20 for IERC20;

    bytes4 public constant IPROVER_INTERFACE_ID = 0xd8e1f34f; //type(IProver).interfaceId

    // Mapping of intent hash on the src chain to its fulfillment
    mapping(bytes32 => ClaimantAndBatcherReward) public fulfilled;

    // Mapping of solvers to if they are whitelisted
    mapping(address => bool) public solverWhitelist;

    // Is solving public
    bool public isSolvingPublic;

    // minimum reward to be included in a fulfillHyperBatched tx, to be paid out to the sender of the batch
    uint96 public minBatcherReward;

    /**
     * @notice Initializes the Inbox contract
     * @param _owner Address with access to privileged functions
     * @param _isSolvingPublic Whether solving is public at start
     * @param _solvers Initial whitelist of solvers (only relevant if solving is not public)
     */
    constructor(
        address _owner,
        bool _isSolvingPublic,
        uint96 _minBatcherReward,
        address[] memory _solvers
    ) Ownable(_owner) {
        isSolvingPublic = _isSolvingPublic;
        minBatcherReward = _minBatcherReward;
        for (uint256 i = 0; i < _solvers.length; ++i) {
            solverWhitelist[_solvers[i]] = true;
            emit SolverWhitelistChanged(_solvers[i], true);
        }
    }

    /**
     * @notice Fulfills an intent to be proven via storage proofs
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @return Array of execution results from each call
     */
    function fulfillStorage(
        Route memory _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash
    ) public payable override returns (bytes[] memory) {
        (bytes[] memory result, ) = _fulfill(
            _route,
            _rewardHash,
            _claimant,
            _expectedHash
        );

        fulfilled[_expectedHash] = ClaimantAndBatcherReward(
            _claimant,
            uint96(0)
        );

        emit ToBeProven(_expectedHash, _route.source, _claimant);

        return result;
    }

    /**
     * @notice Fulfills an intent and initiates proving via message bridge
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _localProver Address of prover on the destination chain
     * @param _sourceChainProver Address of prover on the source chain
     */
    function fulfillMessageBridge(
        Route memory _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash,
        address _localProver,
        address _sourceChainProver,
        bytes calldata _data
    ) public payable returns (bytes[] memory) {
        (bytes[] memory results, uint256 currentBalance) = _fulfill(
            _route,
            _rewardHash,
            _claimant,
            _expectedHash
        );

        fulfilled[_expectedHash] = ClaimantAndBatcherReward(
            _claimant,
            uint96(0)
        );

        bytes32[] memory hashes = new bytes32[](1);
        address[] memory claimants = new address[](1);
        hashes[0] = _expectedHash;
        claimants[0] = _claimant;

        uint256 fee = MessageBridgeProver(_localProver).fetchFee(
            _route.source,
            hashes,
            claimants,
            _sourceChainProver,
            _data
        );
        if (currentBalance < fee) {
            revert InsufficientFee(fee);
        }
        if (currentBalance > fee) {
            (bool success, ) = payable(msg.sender).call{
                value: currentBalance - fee
            }("");
            if (!success) {
                revert NativeTransferFailed();
            }
        }
        MessageBridgeProver(_localProver).initiateProving{value: fee}(
            _route.source,
            hashes,
            claimants,
            _sourceChainProver,
            _data
        );

        return results;
    }

    /**
     * @notice Fulfills an intent to be proven in a batch via a meessage bridge
     * @dev Less expensive but slower fulfillMessageBridge. Batch dispatched when sendBatch is called.
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _localProver Address of prover on the destination chain
     * @param _sourceChainProver Address of prover on the source chain
     */
    function fulfillMessageBridgeBatched(
        Route calldata _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash,
        address _localProver,
        address _sourceChainProver
    ) external payable returns (bytes[] memory) {
        emit AddToBatch(
            _expectedHash,
            _route.source,
            _claimant,
            _localProver,
            _sourceChainProver
        );

        (bytes[] memory results, uint256 remainingValue) = _fulfill(
            _route,
            _rewardHash,
            _claimant,
            _expectedHash
        );

        if (remainingValue < minBatcherReward) {
            revert InsufficientBatcherReward(minBatcherReward);
        }

        fulfilled[_expectedHash] = ClaimantAndBatcherReward(
            _claimant,
            uint96(remainingValue)
        );

        return results;
    }

    /**
     * @notice initiates proving of a batch of fulfilled intents
     * @dev Intent hashes must correspond to fulfilled intents from specified source chain
     * @param _sourceChainID Chain ID of the source chain

     * @param _intentHashes Hashes of the intents to be proven
     * @param _localProver Address of prover on the destination chain
     * @param _sourceChainProver Address of prover on the source chain
     */
    function messageBridgeSendBatch(
        uint256 _sourceChainID,
        bytes32[] calldata _intentHashes,
        address _localProver,
        address _sourceChainProver,
        bytes calldata _data
    ) public payable {
        uint256 size = _intentHashes.length;
        address[] memory claimants = new address[](size);
        uint256 reward = 0;
        for (uint256 i = 0; i < size; ++i) {
            ClaimantAndBatcherReward storage fulfillment = fulfilled[
                _intentHashes[i]
            ];
            address claimant = fulfillment.claimant;
            reward += fulfillment.reward;
            fulfillment.reward = 0;

            if (claimant == address(0)) {
                revert IntentNotFulfilled(_intentHashes[i]);
            }
            claimants[i] = claimant;
        }

        uint256 fee = MessageBridgeProver(_localProver).fetchFee(
            _sourceChainID,
            _intentHashes,
            claimants,
            _sourceChainProver,
            _data
        );
        if (msg.value < fee) {
            revert InsufficientFee(fee);
        }
        (bool success, ) = payable(msg.sender).call{
            value: msg.value + reward - fee
        }("");
        if (!success) {
            revert NativeTransferFailed();
        }

        emit BatchSent(_intentHashes, _sourceChainID);

        MessageBridgeProver(_localProver).initiateProving{value: fee}(
            _sourceChainID,
            _intentHashes,
            claimants,
            _sourceChainProver,
            _data
        );
    }

    /**
     * @notice Makes solving public if currently restricted
     * @dev Cannot be reversed once made public
     */
    function makeSolvingPublic() public onlyOwner {
        if (!isSolvingPublic) {
            isSolvingPublic = true;
            emit SolvingIsPublic();
        }
    }

    /**
     * @notice Changes minimum reward for batcher
     * @param _minBatcherReward New minimum reward
     */
    function setMinBatcherReward(uint96 _minBatcherReward) public onlyOwner {
        minBatcherReward = _minBatcherReward;
        emit MinBatcherRewardSet(_minBatcherReward);
    }

    /**
     * @notice Updates the solver whitelist
     * @dev Whitelist is ignored if solving is public
     * @param _solver Address of the solver
     * @param _canSolve Whether solver should be whitelisted
     */
    function changeSolverWhitelist(
        address _solver,
        bool _canSolve
    ) public onlyOwner {
        solverWhitelist[_solver] = _canSolve;
        emit SolverWhitelistChanged(_solver, _canSolve);
    }

    /**
     * @notice Internal function to fulfill intents
     * @dev Validates intent and executes calls
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant The reward recipient address
     * @param _expectedHash The expected intent hash
     * @return Array of execution results
     */
    function _fulfill(
        Route memory _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash
    ) internal returns (bytes[] memory, uint256) {
        if (_route.destination != block.chainid) {
            revert WrongChain(_route.destination);
        }

        if (!isSolvingPublic && !solverWhitelist[msg.sender]) {
            revert UnauthorizedSolveAttempt(msg.sender);
        }

        bytes32 routeHash = keccak256(abi.encode(_route));
        bytes32 intentHash = keccak256(
            abi.encodePacked(routeHash, _rewardHash)
        );

        if (_route.inbox != address(this)) {
            revert InvalidInbox(_route.inbox);
        }
        if (intentHash != _expectedHash) {
            revert InvalidHash(_expectedHash);
        }
        if (fulfilled[intentHash].claimant != address(0)) {
            revert IntentAlreadyFulfilled(intentHash);
        }
        if (_claimant == address(0)) {
            revert ZeroClaimant();
        }

        emit Fulfillment(_expectedHash, _route.source, _claimant);

        uint256 routeTokenCount = _route.tokens.length;
        // Transfer ERC20 tokens to the inbox
        for (uint256 i = 0; i < routeTokenCount; ++i) {
            TokenAmount memory approval = _route.tokens[i];
            IERC20(approval.token).safeTransferFrom(
                msg.sender,
                address(this),
                approval.amount
            );
        }

        // Store the results of the calls
        bytes[] memory results = new bytes[](_route.calls.length);

        // Remaining value after executing calls
        uint256 remainingValue = msg.value;

        for (uint256 i = 0; i < _route.calls.length; ++i) {
            Call memory call = _route.calls[i];
            if (call.target.code.length == 0 && call.data.length > 0) {
                // no code at this address
                revert CallToEOA(call.target);
            }
            if (IERC165(call.target).supportsInterface(IPROVER_INTERFACE_ID)) {
                // no executing calls on the prover
                revert CallToProver();
            }
            (bool success, bytes memory result) = call.target.call{
                value: call.value
            }(call.data);
            if (!success) {
                revert IntentCallFailed(
                    call.target,
                    call.data,
                    call.value,
                    result
                );
            }
            remainingValue -= call.value;
            results[i] = result;
        }
        return (results, remainingValue);
    }

    receive() external payable {}
}
