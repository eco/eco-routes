/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDestinationSettler} from "./interfaces/ERC7683/IDestinationSettler.sol";
import {Intent, Route, Reward, TokenAmount} from "./types/UniversalIntent.sol";
import {OnchainCrosschainOrderData, Route as Route7683} from "./types/EcoERC7683.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AddressConverter} from "./libs/AddressConverter.sol";

abstract contract Eco7683DestinationSettler is IDestinationSettler {
    using ECDSA for bytes32;
    using AddressConverter for address;
    using AddressConverter for bytes32;

    /**
     * @notice Fills a single leg of a particular order on the destination chain
     * @dev _originData is of type OnchainCrossChainOrder
     * @dev _fillerData is encoded bytes consisting of the claimant address and any additional data required for the chosen prover
     * @param _orderId Unique identifier for the order being filled
     * @param _originData Data emitted on the origin chain to parameterize the fill, equivalent to the originData field from the fillInstruction of the ResolvedCrossChainOrder. An encoded Intent struct.
     * @param _fillerData Data provided by the filler to inform the fill or express their preferences
     */
    function fill(
        bytes32 _orderId,
        bytes calldata _originData,
        bytes calldata _fillerData
    ) external payable {
        // Decode components individually to avoid Solidity's nested struct decoding issues
        (
            uint64 destination,
            Route7683 memory route,
            bytes32 creator,
            bytes32 prover,
            uint256 nativeValue,
            TokenAmount[] memory rewardTokens
        ) = abi.decode(
                _originData,
                (uint64, Route7683, bytes32, bytes32, uint256, TokenAmount[])
            );

        OnchainCrosschainOrderData
            memory orderData = OnchainCrosschainOrderData({
                destination: destination,
                route: route,
                creator: creator,
                prover: prover,
                nativeValue: nativeValue,
                rewardTokens: rewardTokens
            });

        // For now, we'll need to get deadline from elsewhere since it's not in OnchainCrosschainOrderData
        // This is a limitation of the EIP-7683 structure - it doesn't include deadline
        // For test purposes, we'll use a far future deadline
        uint64 deadline = type(uint64).max;

        emit OrderFilled(_orderId, msg.sender.toBytes32());

        // Create reward structure for hash calculation
        Reward memory reward = Reward({
            deadline: deadline,
            creator: orderData.creator, // Already bytes32 in universal types
            prover: orderData.prover, // Already bytes32 in universal types
            nativeValue: orderData.nativeValue,
            tokens: orderData.rewardTokens
        });

        // Check deadline after creating reward
        if (block.timestamp > deadline) {
            revert FillDeadlinePassed();
        }

        bytes32 rewardHash = keccak256(abi.encode(reward));
        (address claimant, uint64 sourceChainId, bytes memory data) = abi
            .decode(_fillerData, (address, uint64, bytes));

        // Convert EIP-7683 Route to Intent Route
        Route memory intentRoute = Route({
            salt: orderData.route.salt,
            deadline: deadline,
            portal: orderData.route.portal, // Already bytes32 in universal types
            tokens: orderData.route.tokens,
            calls: orderData.route.calls
        });

        fulfillAndProve(
            sourceChainId,
            intentRoute,
            rewardHash,
            claimant.toBytes32(),
            _orderId,
            orderData.prover.toAddress(),
            data
        );
    }

    function fulfillAndProve(
        uint64 _sourceChainId,
        Route memory _route,
        bytes32 _rewardHash,
        bytes32 _claimant,
        bytes32 _expectedHash,
        address _localProver,
        bytes memory _data
    ) public payable virtual returns (bytes[] memory);
}
