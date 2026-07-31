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
     * @notice Unauthorized call detected
     *  @param expected Address that should have been the sender
     *  @param actual Address that actually sent the message
     */
    error UnauthorizedSender(address expected, address actual);

    /**
     * @notice Unauthorized incoming proof from source chain
     * @param sender Address that initiated the proof (as bytes32 for cross-VM compatibility)
     */
    error UnauthorizedIncomingProof(bytes32 sender);

    /**
     * @notice Messenger contract address cannot be zero
     * @dev MessengerContract is a general term for the message-passing contract that handles
     *      cross-chain communication, used to consolidate errors. Specific implementations'
     *      terminology will reflect that of the protocol and as such may not match up with what is
     *      used in Eco's interface contract.
     */
    error MessengerContractCannotBeZeroAddress();

    /**
     * @notice Message origin chain domain ID cannot be zero
     * @dev DomainID is a general term for the chain identifier used by cross-chain messaging protocols,
     *      used to consolidate errors. Specific implementations' terminology will reflect that of the
     *      protocol and as such may not match up with what is used in Eco's interface contract.
     */
    error MessageOriginChainDomainIDCannotBeZero();

    /**
     * @notice Message sender address cannot be zero
     */
    error MessageSenderCannotBeZeroAddress();

    /**
     * @notice message is invalid
     */
    error InvalidProofMessage();

    /**
     * @notice A trusted mapping entry from a bridge origin domain to its EVM chainId
     * @param domain Bridge-specific origin domain id (Hyperlane domain / LZ eid / CCIP selector / Meta domain)
     * @param chainId EVM chainId that `domain` corresponds to
     */
    struct Domain {
        uint64 domain;
        uint64 chainId;
    }

    /// @notice Origin domain has no registered chainId (strict-map provers)
    error UnregisteredDomain(uint64 domain);

    /// @notice Self-reported header chainId does not match the chainId resolved from the origin domain
    error ChainIdMismatch(uint64 domain, uint64 expected, uint64 actual);

    /// @notice Domain config entry is invalid (zero domain, zero chainId, a
    ///         duplicate domain, or a duplicate chainId)
    error InvalidDomainConfig(uint64 domain, uint64 chainId);

    /// @notice Emitted once per accepted (domain -> chainId) entry at construction
    /// @dev Lets the immutable, setter-less domain map be audited after deploy
    /// @param domain Bridge-specific origin domain id
    /// @param chainId EVM chainId that `domain` is trusted to represent
    event DomainRegistered(uint64 indexed domain, uint64 indexed chainId);

    /**
     * @notice Refund of overpaid/forwarded ETH to the caller failed
     * @dev Raised when the low-level refund call reverts. The recipient is
     *      always the tx caller, so this surfaces a genuinely-unpayable
     *      caller loudly instead of silently stranding their ETH as dust.
     * @param recipient Address the refund was being sent to
     * @param amount Amount of ETH that could not be refunded
     */
    error RefundFailed(address recipient, uint256 amount);

    /**
     * @notice Calculates the fee required for message dispatch
     * @param domainID Bridge-specific domain ID of the source chain (where the intent was created).
     *        IMPORTANT: This is NOT the chain ID. Each bridge provider uses their own
     *        domain ID mapping system. You MUST check with the specific bridge provider
     *        (Hyperlane, LayerZero, Metalayer) documentation to determine the correct
     *        domain ID for the source chain.
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     * @param data Additional data for message formatting.
     *        Specific format varies by implementation:
     *        - HyperProver: (bytes32 sourceChainProver, bytes metadata, address hookAddr, [uint256 gasLimitOverride])
     *        - MetaProver: (bytes32 sourceChainProver, [uint256 gasLimitOverride])
     *        - LayerZeroProver: (bytes32 sourceChainProver, uint128 gasLimit)
     * @return Fee amount required for message dispatch
     */
    function fetchFee(
        uint64 domainID,
        bytes calldata encodedProofs,
        bytes calldata data
    ) external view returns (uint256);

    /**
     * @notice Domain ID is too large to fit in uint32
     * @param domainId The domain ID that is too large
     */
    error DomainIdTooLarge(uint64 domainId);
}
