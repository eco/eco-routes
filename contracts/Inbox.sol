// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IProver} from "./interfaces/IProver.sol";
import {Eco7683DestinationSettler} from "./Eco7683DestinationSettler.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IInbox} from "./interfaces/IInbox.sol";

import {Intent, Route, Call, TokenAmount} from "./types/Intent.sol";
import {Semver} from "./libs/Semver.sol";

/**
 * @title Inbox
 * @notice Main entry point for fulfilling intents on the destination chain
 * @dev Validates intent hash authenticity, executes calldata, and enables provers
 * to claim rewards on the source chain by checking the fulfilled mapping
 */
contract Inbox is IInbox, Eco7683DestinationSettler, Semver {
    using TypeCasts for address;
    using SafeERC20 for IERC20;

    /**
     * @notice Interface ID for IProver used to detect prover contracts
     */
    bytes4 public constant IPROVER_INTERFACE_ID = 0xd8e1f34f; //type(IProver).interfaceId

    /**
     * @notice Mapping of intent hashes to their claimant addresses
     * @dev Stores the address eligible to claim rewards for each fulfilled intent
     */
    mapping(bytes32 => address) public fulfilled;

    /**
     * @notice Initializes the Inbox contract
     */
    constructor() {}

    /**
     * @notice Fulfills an intent to be proven via storage proofs
     * @dev Validates intent hash, executes calls, and marks as fulfilled
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward details
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _localProver The prover contract to use for verification
     * @return Array of execution results from each call
     */
    function fulfill(
        Route memory _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash,
        address _localProver
    ) external payable override returns (bytes[] memory) {
        bytes[] memory result = _fulfill(
            _route,
            _rewardHash,
            _claimant,
            _expectedHash,
            _localProver
        );

        return result;
    }

    /**
     * @notice Fulfills an intent and initiates proving in one transaction
     * @dev Executes intent actions and sends proof message to source chain
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward details
     * @param _claimant The address that will receive the reward on the source chain
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _localProver Address of prover on the destination chain
     * @param _data Additional data for message formatting
     * @return Array of execution results
     */
    function fulfillAndProve(
        Route memory _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash,
        address _localProver,
        bytes memory _data
    )
        public
        payable
        override(Eco7683DestinationSettler, IInbox)
        returns (bytes[] memory)
    {
        bytes[] memory result = _fulfill(
            _route,
            _rewardHash,
            _claimant,
            _expectedHash,
            _localProver
        );

        bytes32[] memory hashes = new bytes32[](1);
        address[] memory claimants = new address[](1);
        hashes[0] = _expectedHash;
        claimants[0] = _claimant;

        initiateProving(_route.source, hashes, _localProver, _data);
        return result;
    }

    /**
     * @notice Initiates proving process for fulfilled intents
     * @dev Sends message to source chain to verify intent execution
     * @param _sourceChainId Chain ID of the source chain
     * @param _intentHashes Array of intent hashes to prove
     * @param _localProver Address of prover on the destination chain
     * @param _data Additional data for message formatting
     */
    function initiateProving(
        uint256 _sourceChainId,
        bytes32[] memory _intentHashes,
        address _localProver,
        bytes memory _data
    ) public payable {
        if (_localProver == address(0)) {
            // storage prover case, this method should do nothing
            return;
        }
        uint256 size = _intentHashes.length;
        address[] memory claimants = new address[](size);
        for (uint256 i = 0; i < size; ++i) {
            address claimant = fulfilled[_intentHashes[i]];

            if (claimant == address(0)) {
                revert IntentNotFulfilled(_intentHashes[i]);
            }
            claimants[i] = claimant;
        }
        IProver(_localProver).prove{value: msg.value}(
            msg.sender,
            _sourceChainId,
            _intentHashes,
            claimants,
            _data
        );
    }

    /**
     * @notice Internal function to fulfill intents
     * @dev Validates intent and executes calls
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant The reward recipient address
     * @param _expectedHash The expected intent hash
     * @param _localProver The prover contract to use
     * @return Array of execution results
     */
    function _fulfill(
        Route memory _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash,
        address _localProver
    ) internal returns (bytes[] memory) {
        if (_route.destination != block.chainid) {
            revert WrongChain(_route.destination);
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
        if (fulfilled[intentHash] != address(0)) {
            revert IntentAlreadyFulfilled(intentHash);
        }
        if (_claimant == address(0)) {
            revert ZeroClaimant();
        }

        fulfilled[intentHash] = _claimant;

        emit Fulfillment(_expectedHash, _route.source, _localProver, _claimant);

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

        for (uint256 i = 0; i < _route.calls.length; ++i) {
            Call memory call = _route.calls[i];
            if (call.target.code.length == 0 && call.data.length > 0) {
                // no code at this address
                revert CallToEOA(call.target);
            }
            (bool isProverCall, ) = (call.target).call(
                abi.encodeWithSignature(
                    "supportsInterface(bytes4)",
                    IPROVER_INTERFACE_ID
                )
            );
            if (isProverCall) {
                // call to prover
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
            results[i] = result;
        }
        return (results);
    }

    /**
     * @notice Allows the contract to receive ETH
     * @dev Required for handling ETH transfer for intent execution
     */
    receive() external payable {}
}
