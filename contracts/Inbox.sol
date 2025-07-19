// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IProver} from "./interfaces/IProver.sol";
import {IInbox} from "./interfaces/IInbox.sol";

import {Route, Call, TokenAmount} from "./types/Intent.sol";
import {Semver} from "./libs/Semver.sol";

import {DestinationSettler} from "./ERC7683/DestinationSettler.sol";

/**
 * @title Inbox
 * @notice Main entry point for fulfilling intents on the destination chain
 * @dev Validates intent hash authenticity, executes calldata, and enables provers
 * to claim rewards on the source chain by checking the fulfilled mapping
 */
abstract contract Inbox is DestinationSettler, IInbox {
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
     * @dev Sets up the base contract for handling intent fulfillment on destination chains
     */
    constructor() {}

    /**
     * @notice Fulfills an intent to be proven via storage proofs
     * @dev Validates intent hash, executes calls, and marks as fulfilled
     * @param intentHash The hash of the intent to fulfill
     * @param route The route of the intent
     * @param rewardHash The hash of the reward details
     * @param claimant Cross-VM compatible claimant identifier
     * @return Array of execution results from each call
     */
    function fulfill(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant
    ) external payable returns (bytes[] memory) {
        bytes[] memory result = _fulfill(
            intentHash,
            route,
            rewardHash,
            claimant
        );

        return result;
    }

    /**
     * @notice Fulfills an intent and initiates proving in one transaction
     * @dev Executes intent actions and sends proof message to source chain
     * @param intentHash The hash of the intent to fulfill
     * @param route The route of the intent
     * @param rewardHash The hash of the reward details
     * @param claimant Cross-VM compatible claimant identifier
     * @param prover Address of prover on the destination chain
     * @param source The source chain ID where the intent was created
     * @param data Additional data for message formatting
     * @return Array of execution results
     */
    function fulfillAndProve(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        address prover,
        uint64 source,
        bytes memory data
    )
        public
        payable
        override(DestinationSettler, IInbox)
        returns (bytes[] memory)
    {
        // Calculate total value needed for route calls
        uint256 routeValue = 0;
        for (uint256 i = 0; i < route.calls.length; ++i) {
            routeValue += route.calls[i].value;
        }

        bytes[] memory result = _fulfill(
            intentHash,
            route,
            rewardHash,
            claimant
        );

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = intentHash;

        // Send remaining value to prover (after route calls)
        uint256 proverValue = msg.value >= routeValue
            ? msg.value - routeValue
            : 0;

        // Get claimants for prove call
        bytes32[] memory claimants = new bytes32[](1);
        claimants[0] = claimant;

        if (proverValue > 0) {
            IProver(prover).prove{value: proverValue}(
                msg.sender,
                source,
                hashes,
                claimants,
                data
            );
        } else {
            IProver(prover).prove(msg.sender, source, hashes, claimants, data);
        }
        return result;
    }

    /**
     * @notice Initiates proving process for fulfilled intents
     * @dev Sends message to source chain to verify intent execution
     * @param source Chain ID of the source chain
     * @param prover Address of prover on the destination chain
     * @param intentHashes Array of intent hashes to prove
     * @param data Additional data for message formatting
     */
    function prove(
        uint256 source,
        address prover,
        bytes32[] memory intentHashes,
        bytes memory data
    ) public payable virtual {
        uint256 size = intentHashes.length;
        bytes32[] memory claimants = new bytes32[](size);

        for (uint256 i = 0; i < size; ++i) {
            bytes32 claimantBytes = fulfilled[intentHashes[i]];

            if (claimantBytes == bytes32(0)) {
                revert IntentNotFulfilled(intentHashes[i]);
            }
            claimants[i] = claimantBytes;
        }

        IProver(prover).prove{value: msg.value}(
            msg.sender,
            source,
            intentHashes,
            claimants,
            data
        );
    }

    /**
     * @notice Internal function to fulfill intents
     * @dev Validates intent and executes calls
     * @param intentHash The hash of the intent to fulfill
     * @param route The route of the intent
     * @param rewardHash The hash of the reward
     * @param claimant Cross-VM compatible claimant identifier
     * @return Array of execution results
     */
    function _fulfill(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant
    ) internal returns (bytes[] memory) {
        // Check if the route has expired
        if (block.timestamp > route.deadline) {
            revert IntentExpired();
        }

        bytes32 routeHash = keccak256(abi.encode(route));
        bytes32 computedIntentHash = keccak256(
            abi.encodePacked(uint64(block.chainid), routeHash, rewardHash)
        );

        if (route.portal != address(this)) {
            revert InvalidPortal(route.portal);
        }
        if (computedIntentHash != intentHash) {
            revert InvalidHash(intentHash);
        }
        if (fulfilled[intentHash] != bytes32(0)) {
            revert IntentAlreadyFulfilled(intentHash);
        }
        if (claimant == bytes32(0)) {
            revert ZeroClaimant();
        }

        fulfilled[intentHash] = claimant;

        emit IntentFulfilled(intentHash, claimant);

        uint256 tokensLength = route.tokens.length;
        // Transfer ERC20 tokens to the portal
        for (uint256 i = 0; i < tokensLength; ++i) {
            TokenAmount memory approval = route.tokens[i];
            IERC20(approval.token).safeTransferFrom(
                msg.sender,
                address(this),
                approval.amount
            );
        }

        // Store the results of the calls
        bytes[] memory results = new bytes[](route.calls.length);

        for (uint256 i = 0; i < route.calls.length; ++i) {
            Call memory call = route.calls[i];
            address target = call.target;
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
