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

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the immutable oracle address
     * @return Address of the oracle that signs proofs
     */
    function ORACLE() external view returns (address);

    /**
     * @notice Returns the EIP-712 type hash for proofs
     * @return Type hash used for signature verification
     */
    function PROOF_TYPEHASH() external view returns (bytes32);
}

