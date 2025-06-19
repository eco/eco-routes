/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDestinationSettler} from "./interfaces/ERC7683/IDestinationSettler.sol";
import {Intent, Route} from "./types/Intent.sol";
import {TypeCasts} from "@hyperlane-xyz/core/contracts/libs/TypeCasts.sol";

abstract contract Eco7683DestinationSettler is IDestinationSettler {
    /**
     * @notice Fills a single leg of a particular order on the destination chain
     * @dev _originData is of type OnchainCrossChainOrder
     * @dev _fillerData is encoded bytes consisting of the claimant address and any additional data required for the chosen prover
     * @param _orderId Unique identifier for the order being filled
     * @param _originData Data emitted on the origin chain to parameterize the fill, equivalent to the originData field from the fillInstruction of the ResolvedCrossChainOrder. An encoded Intent struct.
     * @param _fillerData Data provided by the filler to inform the fill or express their preferences
     * @dev _fillerdata should contain the address of the claimant, the address of the prover on the destination chain, and any additional data required for the chosen prover, and any additional data required for the chosen prover
     */
    function fill(
        bytes32 _orderId,
        bytes calldata _originData,
        bytes calldata _fillerData
    ) external payable {
        Intent memory intent = abi.decode(_originData, (Intent));
        if (block.timestamp > intent.reward.deadline) {
            revert FillDeadlinePassed();
        }

        emit OrderFilled(_orderId, msg.sender);

        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        (address claimant, address localProver, bytes memory data) = abi.decode(
            _fillerData,
            (address, address, bytes)
        );
        fulfillAndProve(
            intent.route,
            rewardHash,
            TypeCasts.addressToBytes32(claimant),
            _orderId,
            localProver,
            data
        );
    }

    function fulfillAndProve(
        Route memory _route,
        bytes32 _rewardHash,
        bytes32 _claimant,
        bytes32 _expectedHash,
        address _localProver,
        bytes memory _data
    ) public payable virtual returns (bytes[] memory);
}
