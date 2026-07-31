/* -*- c-basic-offset: 4 -*- */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";
import {IMessageBridgeProver} from "../interfaces/IMessageBridgeProver.sol";
import {Whitelist} from "../libs/Whitelist.sol";

/**
 * @title MessageBridgeProver
 * @notice Abstract contract for cross-chain message-based proving mechanisms
 * @dev Extends BaseProver with functionality for message bridge provers like Hyperlane and Metalayer
 */
abstract contract MessageBridgeProver is
    BaseProver,
    IMessageBridgeProver,
    Whitelist
{
    /**
     * @notice Minimum gas limit for cross-chain message dispatch
     * @dev Set at deployment and cannot be changed afterward. Gas limits below this value will be increased to this minimum.
     */
    uint256 public immutable MIN_GAS_LIMIT;

    /**
     * @notice Default minimum gas limit for cross-chain messages
     * @dev Used if no specific value is provided during contract deployment
     */
    uint256 private constant DEFAULT_MIN_GAS_LIMIT = 200_000;

    /**
     * @notice Trusted map from bridge origin domain to the EVM chainId it represents
     * @dev Constructor-set, no setter (effectively immutable). Read by _resolveChainId.
     */
    mapping(uint64 => uint64) internal _chainIdByDomain;

    /**
     * @notice Initializes the MessageBridgeProver contract
     * @param portal Address of the Portal contract
     * @param provers Array of trusted prover addresses (as bytes32 for cross-VM compatibility)
     * @param minGasLimit Minimum gas limit for cross-chain messages (200k if not specified or zero)
     * @param domainConfig Trusted origin-domain-to-chainId mapping entries
     */
    constructor(
        address portal,
        bytes32[] memory provers,
        uint256 minGasLimit,
        Domain[] memory domainConfig
    ) BaseProver(portal) Whitelist(provers) {
        MIN_GAS_LIMIT = minGasLimit > 0 ? minGasLimit : 200_000;

        for (uint256 i = 0; i < domainConfig.length; i++) {
            uint64 domain = domainConfig[i].domain;
            uint64 chainId = domainConfig[i].chainId;
            // Reject zero fields and duplicate domains (via the storage map).
            if (domain == 0 || chainId == 0 || _chainIdByDomain[domain] != 0) {
                revert InvalidDomainConfig(domain, chainId);
            }
            // Reject duplicate chainIds: nothing else ties chainId back to
            // domain, so a transposed or repeated entry would otherwise be
            // accepted silently. O(n^2) over a tiny constructor-only list.
            for (uint256 j = 0; j < i; j++) {
                if (domainConfig[j].chainId == chainId) {
                    revert InvalidDomainConfig(domain, chainId);
                }
            }
            _chainIdByDomain[domain] = chainId;
            emit DomainRegistered(domain, chainId);
        }
    }

    /**
     * @notice Returns the EVM chainId registered for a bridge origin domain (0 if unset)
     * @param domain Bridge-specific origin domain id
     */
    function chainIdByDomain(uint64 domain) external view returns (uint64) {
        return _chainIdByDomain[domain];
    }

    /**
     * @notice Modifier to restrict function access to a specific sender
     * @param expectedSender Address that is expected to be the sender
     */
    modifier only(address expectedSender) {
        if (msg.sender != expectedSender) {
            revert UnauthorizedSender(expectedSender, msg.sender);
        }

        _;
    }

    /**
     * @notice Send refund to the user if they've overpaid
     * @param recipient Address to send the refund to
     * @param amount Amount to refund
     */
    function _sendRefund(address recipient, uint256 amount) internal {
        if (recipient == address(0) || amount == 0) {
            return;
        }

        // Use a low-level call rather than transfer() and forward all gas
        // (transfer()'s 2300-gas cap is intentionally not used) so that any
        // smart-contract recipient — a smart account, an EIP-7702 wallet, or a
        // contract whose receive() needs more than the 2300-gas stipend — can
        // still receive the refund. The "gas > 2400" concern is satisfied by
        // this uncapped forwarding.
        //
        // On failure we revert (RefundFailed) rather than swallow the boolean.
        // Reverting surfaces a genuinely-unpayable recipient loudly instead of
        // silently stranding the caller's ETH as dust with no sweep/rescue path.
        // The refund recipient is always the tx caller (Inbox.prove passes
        // msg.sender), so a revert only self-DoSes that caller — there is no
        // third-party griefing vector. Reentrancy remains contained: this is the
        // terminal statement of prove() (no post-refund state), the nonReentrant
        // guard is held for the whole prove, and Inbox.prove has already drained
        // the Portal's balance before this callback, so a reentrant prove()
        // carries 0 value.
        (bool ok, ) = payable(recipient).call{value: amount}("");
        if (!ok) revert RefundFailed(recipient, amount);
    }

    /**
     * @notice Resolves the EVM chainId a message from `originDomain` is allowed to record
     * @dev Base implementation is STRICT: reverts if the domain is not registered.
     *      Hyperlane/Meta override this to fall back to `originDomain` (domain==chainId).
     * @param originDomain Bridge-specific origin domain id from the receive callback
     * @return chainId The trusted EVM chainId for `originDomain`
     */
    function _resolveChainId(
        uint64 originDomain
    ) internal view virtual returns (uint64) {
        uint64 chainId = _chainIdByDomain[originDomain];
        if (chainId == 0) revert UnregisteredDomain(originDomain);
        return chainId;
    }

    /**
     * @notice Handles cross-chain messages containing proof data
     * @param originDomain Bridge-specific origin domain id of the source of this message
     * @param messageSender Address that dispatched the message (as bytes32 for cross-VM)
     * @param message Encoded message: [chainId (8 bytes, uint64)] + [(intentHash, claimant) pairs]
     */
    function _handleCrossChainMessage(
        uint64 originDomain,
        bytes32 messageSender,
        bytes calldata message
    ) internal {
        // Verify dispatch originated from a whitelisted prover address
        if (!isWhitelisted(messageSender)) {
            revert UnauthorizedIncomingProof(messageSender);
        }

        if (message.length < 8) {
            revert InvalidProofMessage();
        }

        // Header chainId (self-reported by the source Inbox)
        uint64 headerChainId = uint64(bytes8(message[0:8]));

        // Trusted chainId derived from the bridge origin domain
        uint64 expectedChainId = _resolveChainId(originDomain);

        // Cross-check: the payload cannot claim a chain other than its bridge origin
        if (headerChainId != expectedChainId) {
            revert ChainIdMismatch(
                originDomain,
                expectedChainId,
                headerChainId
            );
        }

        _processIntentProofs(message[8:], headerChainId);
    }

    /**
     * @notice Common prove function implementation for message bridge provers
     * @dev Handles fee calculation, validation, and message dispatch
     * @param sender Address that initiated the proving request
     * @param domainID Bridge-specific domain ID of the source chain (where the intent was created).
     *        IMPORTANT: This is NOT the chain ID. Each bridge provider uses their own
     *        domain ID mapping system. You MUST check with the specific bridge provider
     *        (Hyperlane, LayerZero, Metalayer) documentation to determine the correct
     *        domain ID for the source chain.
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     * @param data Additional data for message formatting
     */
    function prove(
        address sender,
        uint64 domainID,
        bytes calldata encodedProofs,
        bytes calldata data
    ) external payable virtual override only(PORTAL) {
        // Calculate fee using implementation-specific logic
        uint256 fee = fetchFee(domainID, encodedProofs, data);

        // Check if enough fee was provided
        if (msg.value < fee) {
            revert InsufficientFee(fee);
        }

        // Calculate refund amount if overpaid
        uint256 refundAmount = msg.value > fee ? msg.value - fee : 0;

        // Dispatch message using implementation-specific logic
        _dispatchMessage(domainID, encodedProofs, data, fee);

        // Send refund if needed
        _sendRefund(sender, refundAmount);
    }

    /**
     * @notice Abstract function to dispatch message via specific bridge
     * @dev Must be implemented by concrete provers (HyperProver, MetaProver)
     * @param sourceChainId Chain ID of the source chain
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     * @param data Additional data for message formatting
     * @param fee Fee amount for message dispatch
     */
    function _dispatchMessage(
        uint64 sourceChainId,
        bytes calldata encodedProofs,
        bytes calldata data,
        uint256 fee
    ) internal virtual;

    /**
     * @notice Fetches fee required for message dispatch
     * @dev Must be implemented by concrete provers to calculate bridge-specific fees
     * @param sourceChainId Chain ID of the source chain
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     * @param data Additional data for message formatting
     * @return Fee amount required for message dispatch
     */
    function fetchFee(
        uint64 sourceChainId,
        bytes calldata encodedProofs,
        bytes calldata data
    ) public view virtual returns (uint256);
}
