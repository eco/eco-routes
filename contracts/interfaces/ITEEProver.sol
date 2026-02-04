// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IProver} from "./IProver.sol";

/**
 * @title ITEEProver
 * @notice Interface for TEEProver with oracle signature verification
 * @dev Extends IProver with oracle-based proving using EIP-712 signatures
 */
interface ITEEProver is IProver {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Oracle address cannot be zero
     */
    error ZeroOracle();

    /**
     * @notice Signature verification failed
     */
    error InvalidSignature();
}
