/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OnchainCrossChainOrder, ResolvedCrossChainOrder, GaslessCrossChainOrder, Output, FillInstruction} from "./types/ERC7683.sol";
import {IOriginSettler} from "./interfaces/ERC7683/IOriginSettler.sol";
import {IDestinationSettler} from "./interfaces/ERC7683/IDestinationSettler.sol";
import {Intent, Reward, Route, TokenAmount} from "./types/Intent.sol";
import {IntentSource} from "./IntentSource.sol";
import {IProver} from "./interfaces/IProver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

abstract contract Eco7683DestinationSettler is IDestinationSettler {
    using ECDSA for bytes32;

    /**
     * @notice Fills a single leg of a particular order on the destination chain
     * @dev _originData is of type OnchainCrossChainOrder
     * @dev _fillerData is encoded bytes consisting of the uint256 prover type and the address claimant if the prover type is Storage (0)
     * and the address claimant, the address postDispatchHook, and the bytes metadata if the prover type is Hyperlane (1)
     * @param _orderId Unique identifier for the order being filled
     * @param _originData Data emitted on the origin chain to parameterize the fill, equivalent to the originData field from the fillInstruction of the ResolvedCrossChainOrder. An encoded Intent struct.
     * @param _fillerData Data provided by the filler to inform the fill or express their preferences
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
        string memory proofType = abi.decode(_fillerData, (string));
        (address claimant, bytes memory data) = abi.decode(
            _fillerData,
            (address, bytes)
        );
        fulfillAndProve(
            intent.route,
            rewardHash,
            claimant,
            _orderId,
            intent.reward.prover,
            data
        );
        // if (keccak256(bytes(proofType)) == keccak256(bytes("Storage"))) {
        //     (, address claimant) = abi.decode(_fillerData, (string, address));
        //     fulfillStorage(intent.route, rewardHash, claimant, _orderId);
        // } else if (
        //     keccak256(bytes(proofType)) == keccak256(bytes("Hyperlane"))
        // ) {
        //     (
        //         ,
        //         address claimant,
        //         address postDispatchHook,
        //         bytes memory metadata
        //     ) = abi.decode(_fillerData, (string, address, address, bytes));
        //     fulfillHyperInstantWithRelayer(
        //         intent.route,
        //         rewardHash,
        //         claimant,
        //         _orderId,
        //         intent.reward.prover,
        //         metadata,
        //         postDispatchHook
        //     );
        // }
    }

    function fulfillAndProve(
        Route memory _route,
        bytes32 _rewardHash,
        address _claimant,
        bytes32 _expectedHash,
        address _localProver,
        bytes memory _data
    ) public payable virtual returns (bytes[] memory);

    // function fulfillStorage(
    //     Route memory _route,
    //     bytes32 _rewardHash,
    //     address _claimant,
    //     bytes32 _expectedHash
    // ) public payable virtual returns (bytes[] memory);

    // function fulfillHyperInstantWithRelayer(
    //     Route memory _route,
    //     bytes32 _rewardHash,
    //     address _claimant,
    //     bytes32 _expectedHash,
    //     address _prover,
    //     bytes memory _metadata,
    //     address _postDispatchHook
    // ) public payable virtual returns (bytes[] memory);
}
