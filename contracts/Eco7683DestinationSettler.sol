/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OnchainCrossChainOrder, ResolvedCrossChainOrder, GaslessCrossChainOrder, Output, FillInstruction} from "./types/EIP7683.sol";
import {IOriginSettler} from "./interfaces/EIP7683/IOriginSettler.sol";
import {IDestinationSettler} from "./interfaces/EIP7683/IDestinationSettler.sol";
import {Intent, Reward, Route, TokenAmount} from "./types/Intent.sol";
import {OnchainCrosschainOrderData} from "./types/EcoEIP7683.sol";
import {IntentSource} from "./IntentSource.sol";
import {Inbox} from "./Inbox.sol";
import {IProver} from "./interfaces/IProver.sol";
import {Semver} from "./libs/Semver.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
contract Eco7683DestinationSettler is IDestinationSettler, Semver {
    using ECDSA for bytes32;

    /**
     * @notice Thrown when the prover does not have a valid proofType
     */
    error BadProver();

    constructor() Semver() {}

    /// @notice Fills a single leg of a particular order on the destination chain
    /// @param orderId Unique order identifier for this order
    /// @param originData Data emitted on the origin to parameterize the fill
    /// @param fillerData Data provided by the filler to inform the fill or express their preferences
    function fill(
        bytes32 orderId,
        bytes calldata originData,
        bytes calldata fillerData
    ) external payable {
        OnchainCrossChainOrder memory order = abi.decode(
            originData,
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
                onchainCrosschainOrderData.tokens
            )
        );
        bytes32 rewardHash = keccak256(abi.encode(intent.reward));
        Inbox inbox = Inbox(payable(intent.route.inbox));
        IProver.ProofType proofType = abi.decode(
            fillerData,
            (IProver.ProofType)
        );

        if (proofType == IProver.ProofType.Storage) {
            (, address claimant) = abi.decode(
                fillerData,
                (IProver.ProofType, address)
            );
            inbox.fulfillStorage{value: msg.value}(
                intent.route,
                rewardHash,
                claimant,
                orderId
            );
        } else if (proofType == IProver.ProofType.Hyperlane) {
            (
                ,
                address claimant,
                address postDispatchHook,
                bytes memory metadata
            ) = abi.decode(
                    fillerData,
                    (IProver.ProofType, address, address, bytes)
                );
            inbox.fulfillHyperInstantWithRelayer{value: msg.value}(
                intent.route,
                rewardHash,
                claimant,
                orderId,
                onchainCrosschainOrderData.prover,
                metadata,
                postDispatchHook
            );
        } else {
            revert BadProver();
        }
    }

    receive() external payable {}
}
