// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProver} from "./IProver.sol";

/**
 * @title IMessageBridgeProver
 * @notice Interface for message-bridge based provers
 * @dev Defines common functionality and events for cross-chain message bridge provers
 */
interface IMessageBridgeProver is IProver {
    /**
     * @notice Insufficient fee provided for cross-chain message dispatch
     * @param requiredFee Amount of fee required
     */
    error InsufficientFee(uint256 requiredFee);

    /**
     * @notice Native token transfer failed
     */
    error NativeTransferFailed();

    /**
     * @notice Unauthorized call to handle() detected
     * @param sender Address that attempted the call
     */
    error UnauthorizedHandle(address sender);

    /**
     * @notice Unauthorized call to initiate proving
     * @param sender Address that initiated
     */
    error UnauthorizedProve(address sender);

    /**
     * @notice Unauthorized incoming proof from source chain
     * @param sender Address that initiated the proof (as bytes32 for cross-VM compatibility)
     */
    error UnauthorizedIncomingProof(bytes32 sender);

    /**
     * @notice Mailbox address cannot be zero
     */
    error MailboxCannotBeZeroAddress();

    /**
     * @notice Router address cannot be zero
     */
    error RouterCannotBeZeroAddress();

    /**
     * @notice Portal address cannot be zero
     */
    error PortalCannotBeZeroAddress();

    /**
     * @notice Invalid chain ID for the origin
     */
    error InvalidOriginChainId();

    /**
     * @notice Sender address cannot be zero
     */
    error SenderCannotBeZeroAddress();

    /**
     * @notice Calculates the fee required for message dispatch
     * @param domainID Domain ID of source chain
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     * @param data Additional data for message formatting.
     *        Specific format varies by implementation:
     *        - HyperProver: (bytes32 sourceChainProver, bytes metadata, address hookAddr, [uint256 gasLimitOverride])
     *        - MetaProver: (bytes32 sourceChainProver, [uint256 gasLimitOverride])
     *        - LayerZeroProver: (bytes32 sourceChainProver, bytes options, [uint256 gasLimitOverride])
     * @return Fee amount required for message dispatch
     */
    function fetchFee(
        uint256 domainID,
        bytes calldata encodedProofs,
        bytes calldata data
    ) external view returns (uint256);
}
