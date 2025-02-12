/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OnchainCrossChainOrder, ResolvedCrossChainOrder, GaslessCrossChainOrder, Output, FillInstruction} from "../types/ERC7683.sol";
import {IOriginSettler} from "../interfaces/ERC7683/IOriginSettler.sol";
import {IDestinationSettler} from "../interfaces/ERC7683/IDestinationSettler.sol";
import {IInbox} from "../interfaces/IInbox.sol";
import {Intent, Reward, Route, TokenAmount} from "../types/Intent.sol";
import {OnchainCrosschainOrderData} from "../types/EcoERC7683.sol";
import {IntentSource} from "../IntentSource.sol";
import {IProver} from "../interfaces/IProver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

abstract contract Eco7683DestinationSettler is IDestinationSettler, IInbox {
    using ECDSA for bytes32;

    /**
     * @notice Emitted when an intent is fulfilled using Hyperlane instant proving
     * @param _orderId Hash of the fulfilled intent
     * @param _solver Address that fulfilled intent
     */
    event orderFilled(bytes32 _orderId, address _solver);

    // address of local hyperlane mailbox
    error BadProver();

    /**
     * @notice Fills a single leg of a particular order on the destination chain
     * @dev _originData is of type OnchainCrossChainOrder
     * @dev _fillerData is encoded bytes consisting of the uint256 prover type and the address claimant if the prover type is Storage (0)
     * and the address claimant, the address postDispatchHook, and the bytes metadata if the prover type is Hyperlane (1)
     * @param _orderId Unique order identifier for this order
     * @param _originData Data emitted on the origin to parameterize the fill
     * @param _fillerData Data provided by the filler to inform the fill or express their preferences
     */
    function fill(
        bytes32 _orderId,
        bytes calldata _originData,
        bytes calldata _fillerData
    ) external payable {
        OnchainCrossChainOrder memory order = abi.decode(
            _originData,
            (OnchainCrossChainOrder)
        );
        OnchainCrosschainOrderData memory onchainCrosschainOrderData = abi
            .decode(order.orderData, (OnchainCrosschainOrderData));
        Intent memory intent = Intent(
            onchainCrosschainOrderData.route,
            Reward(
                onchainCrosschainOrderData.creator,
                onchainCrosschainOrderData.prover,
                order.fillDeadline,
                onchainCrosschainOrderData.nativeValue,
                onchainCrosschainOrderData.rewardTokens
            )
        );
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        IProver.ProofType proofType = abi.decode(
            _fillerData,
            (IProver.ProofType)
        );
        if (proofType == IProver.ProofType.Storage) {
            (, address claimant) = abi.decode(
                _fillerData,
                (IProver.ProofType, address)
            );
            IInbox(address(this)).fulfillStorage{value: msg.value}(
                intent.route,
                rewardHash,
                claimant,
                _orderId
            );
        } else if (proofType == IProver.ProofType.Hyperlane) {
            (
                ,
                address claimant,
                address postDispatchHook,
                bytes memory metadata
            ) = abi.decode(
                    _fillerData,
                    (IProver.ProofType, address, address, bytes)
                );
            IInbox(address(this)).fulfillHyperInstantWithRelayer{
                value: msg.value
            }(
                intent.route,
                rewardHash,
                claimant,
                _orderId,
                onchainCrosschainOrderData.prover,
                metadata,
                postDispatchHook
            );
        } else {
            revert BadProver();
        }
    }
}
