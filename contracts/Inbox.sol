// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IProver} from "./interfaces/IProver.sol";
import {IInbox} from "./interfaces/IInbox.sol";
import {IExecutor} from "./interfaces/IExecutor.sol";

import {Route, Call, TokenAmount} from "./types/Intent.sol";
import {Semver} from "./libs/Semver.sol";

import {DestinationSettler} from "./ERC7683/DestinationSettler.sol";
import {Executor} from "./Executor.sol";

/**
 * @title Inbox
 * @notice Main entry point for fulfilling intents on the destination chain
 * @dev Validates intent hash authenticity, executes calldata, and enables provers
 * to claim rewards on the source chain by checking the fulfilled mapping
 */
abstract contract Inbox is DestinationSettler, IInbox {
    using SafeERC20 for IERC20;

    /**
     * @notice Mapping of intent hashes to their claimant identifiers
     * @dev Stores the cross-VM compatible claimant identifier for each fulfilled intent
     */
    mapping(bytes32 => bytes32) public fulfilled;

    IExecutor public immutable executor;

    /**
     * @notice Initializes the Inbox contract
     * @dev Sets up the base contract for handling intent fulfillment on destination chains
     */
    constructor() {
        executor = new Executor();
    }

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
     * @param sourceChainDomainID Domain ID of the source chain where the intent was created
     * @param data Additional data for message formatting
     * @return Array of execution results
     * 
     * @dev WARNING: sourceChainDomainID is NOT necessarily the same as chain ID.
     *      Each bridge provider uses their own domain ID mapping system:
     *      - Hyperlane: Uses custom domain IDs that may differ from chain IDs
     *      - LayerZero: Uses endpoint IDs that map to chains differently
     *      - Metalayer: Uses domain IDs specific to their routing system
     *      You MUST consult the specific bridge provider's documentation to determine
     *      the correct domain ID for the source chain.
     */
    function fulfillAndProve(
        bytes32 intentHash,
        Route memory route,
        bytes32 rewardHash,
        bytes32 claimant,
        address prover,
        uint64 sourceChainDomainID,
        bytes memory data
    )
        public
        payable
        override(DestinationSettler, IInbox)
        returns (bytes[] memory)
    {
        bytes[] memory result = _fulfill(
            intentHash,
            route,
            rewardHash,
            claimant
        );

        // Create array with single intent hash
        bytes32[] memory intentHashes = new bytes32[](1);
        intentHashes[0] = intentHash;

        // Call prove with the intent hash array
        prove(sourceChainDomainID, prover, intentHashes, data);

        return result;
    }

    /**
     * @notice Initiates proving process for fulfilled intents
     * @dev Sends message to source chain to verify intent execution
     * @param sourceChainDomainID Domain ID of the source chain
     * @param prover Address of prover on the destination chain
     * @param intentHashes Array of intent hashes to prove
     * @param data Additional data for message formatting
     * 
     * @dev WARNING: sourceChainDomainID is NOT necessarily the same as chain ID.
     *      Each bridge provider uses their own domain ID mapping system:
     *      - Hyperlane: Uses custom domain IDs that may differ from chain IDs
     *      - LayerZero: Uses endpoint IDs that map to chains differently
     *      - Metalayer: Uses domain IDs specific to their routing system
     *      You MUST consult the specific bridge provider's documentation to determine
     *      the correct domain ID for the source chain.
     */
    function prove(
        uint64 sourceChainDomainID,
        address prover,
        bytes32[] memory intentHashes,
        bytes memory data
    ) public payable virtual {
        uint256 size = intentHashes.length;

        // Encode intent hash/claimant pairs as bytes
        bytes memory encodedClaimants = new bytes(size * 64); // 32 bytes for intent hash + 32 bytes for claimant

        for (uint256 i = 0; i < size; ++i) {
            bytes32 claimantBytes = fulfilled[intentHashes[i]];

            if (claimantBytes == bytes32(0)) {
                revert IntentNotFulfilled(intentHashes[i]);
            }

            // Pack intent hash and claimant into encodedData
            assembly {
                let offset := mul(i, 64)
                mstore(
                    add(add(encodedClaimants, 0x20), offset),
                    mload(add(intentHashes, add(0x20, mul(i, 32))))
                )
                mstore(
                    add(add(encodedClaimants, 0x20), add(offset, 32)),
                    claimantBytes
                )
            }

            // Emit IntentProven event
            emit IntentProven(intentHashes[i], claimantBytes);
        }

        IProver(prover).prove{value: address(this).balance}(
            msg.sender,
            sourceChainDomainID,
            encodedClaimants,
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
            abi.encodePacked(_validateChainID(block.chainid), routeHash, rewardHash)
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

        // Transfer ERC20 tokens to the executor
        uint256 tokensLength = route.tokens.length;

        for (uint256 i = 0; i < tokensLength; ++i) {
            TokenAmount memory token = route.tokens[i];

            IERC20(token.token).safeTransferFrom(
                msg.sender,
                address(executor),
                token.amount
            );
        }

        uint256 callsLength = route.calls.length;
        uint256 callsValue = 0;
        for (uint256 i = 0; i < callsLength; ++i) {
            callsValue += route.calls[i].value;
        }

        return executor.execute{value: callsValue}(route.calls);
    }

    function _validateChainID(uint256 chainId) virtual internal view returns (uint64);

    /**
     * @notice Allows the contract to receive ETH
     * @dev Required for handling ETH transfer for intent execution
     */
    receive() external payable {}
}
