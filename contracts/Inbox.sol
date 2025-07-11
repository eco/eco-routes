// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddressConverter} from "./libs/AddressConverter.sol";
import {IProver} from "./interfaces/IProver.sol";
import {Eco7683DestinationSettler} from "./Eco7683DestinationSettler.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IInbox} from "./interfaces/IInbox.sol";

import {Route, Call, TokenAmount} from "./types/UniversalIntent.sol";
import {Semver} from "./libs/Semver.sol";

/**
 * @title Inbox
 * @notice Main entry point for fulfilling intents on the destination chain
 * @dev Validates intent hash authenticity, executes calldata, and enables provers
 * to claim rewards on the source chain by checking the fulfilled mapping
 */
contract Inbox is IInbox, Eco7683DestinationSettler, Semver {
    using AddressConverter for address;
    using AddressConverter for bytes32;
    using SafeERC20 for IERC20;

    /**
     * @notice Interface ID for IProver used to detect prover contracts
     */
    bytes4 public constant IPROVER_INTERFACE_ID = type(IProver).interfaceId;

    /**
     * @notice Mapping of intent hashes to their claimant identifiers
     * @dev Stores the cross-VM compatible claimant identifier for each fulfilled intent
     */
    mapping(bytes32 => bytes32) public fulfilled;

    /**
     * @notice Initializes the Inbox contract
     */
    constructor() {}

    /**
     * @notice Fulfills an intent to be proven via storage proofs
     * @dev Validates intent hash, executes calls, and marks as fulfilled
     * @param _sourceChainId The source chain ID where the intent was created
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward details
     * @param _claimant Cross-VM compatible claimant identifier
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _localProver The prover contract to use for verification
     * @return Array of execution results from each call
     */
    function fulfill(
        uint64 _sourceChainId,
        Route memory _route,
        bytes32 _rewardHash,
        bytes32 _claimant,
        bytes32 _expectedHash,
        address _localProver
    ) external payable override returns (bytes[] memory) {
        bytes[] memory result = _fulfill(
            _sourceChainId,
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
     * @param _sourceChainId The source chain ID where the intent was created
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward details
     * @param _claimant Cross-VM compatible claimant identifier
     * @param _expectedHash The hash of the intent as created on the source chain
     * @param _localProver Address of prover on the destination chain
     * @param _data Additional data for message formatting
     * @return Array of execution results
     */
    function fulfillAndProve(
        uint64 _sourceChainId,
        Route memory _route,
        bytes32 _rewardHash,
        bytes32 _claimant,
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
            _sourceChainId,
            _route,
            _rewardHash,
            _claimant,
            _expectedHash,
            _localProver
        );

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = _expectedHash;

        initiateProving(_sourceChainId, hashes, _localProver, _data);
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
        bytes32[] memory claimants = new bytes32[](size);
        for (uint256 i = 0; i < size; ++i) {
            bytes32 claimantBytes = fulfilled[_intentHashes[i]];

            if (claimantBytes == bytes32(0)) {
                revert IntentNotFulfilled(_intentHashes[i]);
            }
            claimants[i] = claimantBytes;
        }
        IProver(_localProver).prove{value: address(this).balance}(
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
     * @param _sourceChainId The source chain ID where the intent was created
     * @param _route The route of the intent
     * @param _rewardHash The hash of the reward
     * @param _claimant Cross-VM compatible claimant identifier
     * @param _expectedHash The expected intent hash
     * @param _localProver The prover contract to use
     * @return Array of execution results
     */
    function _fulfill(
        uint64 _sourceChainId,
        Route memory _route,
        bytes32 _rewardHash,
        bytes32 _claimant,
        bytes32 _expectedHash,
        address _localProver
    ) internal returns (bytes[] memory) {
        // Check if the route has expired
        if (block.timestamp > _route.deadline) {
            revert IntentExpired();
        }

        bytes32 routeHash = keccak256(abi.encode(_route));
        bytes32 intentHash = keccak256(
            abi.encodePacked(uint64(block.chainid), routeHash, _rewardHash)
        );

        if (_route.portal != address(this).toBytes32()) {
            revert InvalidPortal(_route.portal.toAddress());
        }
        if (intentHash != _expectedHash) {
            revert InvalidHash(_expectedHash);
        }
        if (fulfilled[intentHash] != bytes32(0)) {
            revert IntentAlreadyFulfilled(intentHash);
        }
        if (_claimant == bytes32(0)) {
            revert ZeroClaimant();
        }

        fulfilled[intentHash] = _claimant;

        emit Fulfillment(
            _expectedHash,
            _sourceChainId,
            _localProver.toBytes32(),
            _claimant
        );

        uint256 routeTokenCount = _route.tokens.length;
        // Transfer ERC20 tokens to the inbox
        for (uint256 i = 0; i < routeTokenCount; ++i) {
            TokenAmount memory approval = _route.tokens[i];
            IERC20(approval.token.toAddress()).safeTransferFrom(
                msg.sender,
                address(this),
                approval.amount
            );
        }

        // Store the results of the calls
        bytes[] memory results = new bytes[](_route.calls.length);

        for (uint256 i = 0; i < _route.calls.length; ++i) {
            Call memory call = _route.calls[i];
            address target = call.target.toAddress();
            if (target.code.length == 0) {
                if (call.data.length > 0) {
                    // no code at this address
                    revert CallToEOA(target);
                }
            } else {
                try
                    IERC165(target).supportsInterface(IPROVER_INTERFACE_ID)
                returns (bool isProverCall) {
                    if (isProverCall) {
                        // call to prover
                        revert CallToProver();
                    }
                } catch {
                    // If target doesn't support ERC-165, continue.
                }
            }

            (bool success, bytes memory result) = target.call{
                value: call.value
            }(call.data);
            if (!success) {
                revert IntentCallFailed(target, call.data, call.value, result);
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
