/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Reward} from "../types/Intent.sol";
import {IPermit} from "./IPermit.sol";

interface IVaultV2 {
    error NotPortalCaller(address caller);
    error InvalidStatusForFunding(Status status);
    error InvalidStatusForWithdrawal(Status status);
    error InvalidStatusForRefund(
        Status status,
        uint256 currentTime,
        uint256 deadline
    );
    error NativeTransferFailed(address to, uint256 amount);
    error InvalidClaimant(address claimant);

    enum Status {
        Initial,
        Funded,
        Withdrawn,
        Refunded
    }

    function fund(
        Reward calldata reward,
        address funder,
        IPermit permit
    ) external payable returns (bool);

    function withdraw(Reward calldata reward, address claimant) external;

    function refund(Reward calldata reward) external;

    function getStatus() external view returns (Status);
}
