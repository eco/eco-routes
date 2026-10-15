// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MessageBridgeProver} from "./MessageBridgeProver.sol";
import {IMessageTransmitterV2} from "../interfaces/cctp/IMessageTransmitterV2.sol";
import {IMessageHandlerV2} from "../interfaces/cctp/IMessageHandlerV2.sol";
import {Semver} from "../libs/Semver.sol";

/**
 * @title CCTPProver
 * @notice Prover that carries (intentHash, claimant) batches over Circle CCTP V2
 *         generic messages (MessageTransmitterV2.sendMessage / receiveMessage)
 * @dev Always sends at minFinalityThreshold 1000 (Fast) and accepts either
 *      attested level on receive. There is no per-domain allowlist: a
 *      receiver that refused Fast from a source that sends Fast would reject
 *      every message on that lane until someone asked Iris to re-attest it at
 *      Finalized (POST /v2/reattest), an extra relay step on every message.
 *      destinationCaller is zero, so anyone may relay. There is no bridge fee;
 *      the relayer pays receiveMessage gas.
 *
 *      CCTP domain 0 is Ethereum, and MessageBridgeProver's constructor rejects
 *      domain 0. The map itself handles key 0 because its "unset" marker is
 *      chainId 0, so this contract passes an empty config to the base and
 *      registers domains itself. The base contract is left unchanged on purpose.
 *
 *      The destination is bridge-attested: Circle signs sourceDomain, and the
 *      strict base _resolveChainId has no fallback. That makes this prover a
 *      valid AggregatorProver member in the same class as LayerZeroProver.
 */
contract CCTPProver is MessageBridgeProver, IMessageHandlerV2, Semver {
    /**
     * @notice Optional per-destination-domain cap on pairs per message
     * @param domain CCTP destination domain
     * @param maxPairs Largest (intentHash, claimant) count a single send may carry
     */
    struct MaxPairs {
        uint32 domain;
        uint16 maxPairs;
    }

    /// @notice Constant indicating this contract uses CCTP for proving
    string public constant PROOF_TYPE = "CCTP";

    /// @notice CCTP "confirmed" level; requesting it makes a message Fast-eligible
    uint32 public constant MIN_FINALITY_THRESHOLD = 1000;

    /// @notice Circle MessageTransmitterV2 on this chain
    address public immutable TRANSMITTER;

    /// @notice CCTP domain of this chain, read from the transmitter at deploy
    uint32 public immutable LOCAL_DOMAIN;

    /// @dev Constructor-set, no setter. 0 means no prover-side cap.
    mapping(uint32 => uint16) private _maxPairsByDomain;

    error TransmitterCannotBeZeroAddress();
    error InvalidMaxPairsConfig(uint32 domain, uint16 maxPairs);
    error InvalidDestinationDomain(uint64 domain);
    error SourceChainProverCannotBeZero();
    error InvalidEncodedProofsLength(uint256 length);
    error TooManyPairs(uint32 domain, uint256 pairs, uint256 maxPairs);

    /// @notice Emitted once per accepted batch cap at construction
    event MaxPairsRegistered(uint32 indexed domain, uint16 maxPairs);

    /**
     * @param portal Address of the Portal contract
     * @param transmitter Circle MessageTransmitterV2 on this chain
     * @param provers Trusted senders as bytes32: EVM CCTPProvers left-padded
     *        (bytes32(uint256(uint160(a)))), the Solana cctp-prover program ID raw
     * @param domainConfig Strict CCTP-domain-to-chainId map; must list every
     *        origin domain accepted. Domain 0 (Ethereum) is allowed.
     * @param maxPairsConfig Optional per-destination batch caps (Solana needs one)
     */
    constructor(
        address portal,
        address transmitter,
        bytes32[] memory provers,
        Domain[] memory domainConfig,
        MaxPairs[] memory maxPairsConfig
    ) MessageBridgeProver(portal, provers, 0, new Domain[](0)) {
        if (transmitter == address(0)) revert TransmitterCannotBeZeroAddress();
        uint32 localDomain = IMessageTransmitterV2(transmitter).localDomain();
        TRANSMITTER = transmitter;
        LOCAL_DOMAIN = localDomain;
        _registerDomains(domainConfig, localDomain);
        _registerMaxPairs(maxPairsConfig, localDomain);
    }

    /**
     * @notice Returns the batch cap for a destination domain (0 = no prover-side cap)
     */
    function maxPairsByDomain(uint32 domain) external view returns (uint16) {
        return _maxPairsByDomain[domain];
    }

    /**
     * @notice Returns the proof type used by this prover
     */
    function getProofType() external pure override returns (string memory) {
        return PROOF_TYPE;
    }

    /**
     * @notice CCTP charges no fee for sendMessage
     * @dev Validates the inputs so a quote fails the same way prove would
     */
    function fetchFee(
        uint64 domainID,
        bytes calldata encodedProofs,
        bytes calldata data
    ) public view override returns (uint256) {
        uint32 destinationDomain = _checkedDestinationDomain(domainID);
        _unpackData(data);
        _checkBatchSize(destinationDomain, encodedProofs.length);
        return 0;
    }

    /**
     * @dev Called by MessageBridgeProver.prove after the fee check and before
     *      the refund. The fee is always 0, so all msg.value is refunded.
     */
    function _dispatchMessage(
        uint64 domainID,
        bytes calldata encodedProofs,
        bytes calldata data,
        uint256 /* fee */
    ) internal override {
        uint32 destinationDomain = _checkedDestinationDomain(domainID);
        bytes32 sourceChainProver = _unpackData(data);
        _checkBatchSize(destinationDomain, encodedProofs.length);

        IMessageTransmitterV2(TRANSMITTER).sendMessage(
            destinationDomain,
            sourceChainProver,
            bytes32(0), // anyone may relay
            MIN_FINALITY_THRESHOLD,
            encodedProofs
        );
    }

    function _checkedDestinationDomain(
        uint64 domainID
    ) internal view returns (uint32) {
        if (domainID > type(uint32).max) revert DomainIdTooLarge(domainID);
        if (domainID == LOCAL_DOMAIN) revert InvalidDestinationDomain(domainID);
        return uint32(domainID);
    }

    function _unpackData(
        bytes calldata data
    ) internal pure returns (bytes32 sourceChainProver) {
        sourceChainProver = abi.decode(data, (bytes32));
        if (sourceChainProver == bytes32(0)) {
            revert SourceChainProverCannotBeZero();
        }
    }

    /// @dev encodedProofs = 8-byte chainId header + n * 64-byte pairs
    function _checkBatchSize(
        uint32 destinationDomain,
        uint256 length
    ) internal view {
        if (length < 8 || (length - 8) % 64 != 0) {
            revert InvalidEncodedProofsLength(length);
        }
        uint256 pairs = (length - 8) / 64;
        uint16 cap = _maxPairsByDomain[destinationDomain];
        if (cap != 0 && pairs > cap) {
            revert TooManyPairs(destinationDomain, pairs, cap);
        }
    }

    /// @dev Same rules as MessageBridgeProver's loop, except domain 0 is
    ///      allowed. Also rejects domains above uint32 and the local domain.
    function _registerDomains(
        Domain[] memory domainConfig,
        uint32 localDomain
    ) private {
        for (uint256 i = 0; i < domainConfig.length; i++) {
            uint64 domain = domainConfig[i].domain;
            uint64 chainId = domainConfig[i].chainId;
            if (
                chainId == 0 ||
                domain > type(uint32).max ||
                domain == localDomain ||
                _chainIdByDomain[domain] != 0
            ) {
                revert InvalidDomainConfig(domain, chainId);
            }
            for (uint256 j = 0; j < i; j++) {
                if (domainConfig[j].chainId == chainId) {
                    revert InvalidDomainConfig(domain, chainId);
                }
            }
            _chainIdByDomain[domain] = chainId;
            emit DomainRegistered(domain, chainId);
        }
    }

    function _registerMaxPairs(
        MaxPairs[] memory maxPairsConfig,
        uint32 localDomain
    ) private {
        for (uint256 i = 0; i < maxPairsConfig.length; i++) {
            uint32 domain = maxPairsConfig[i].domain;
            uint16 maxPairs = maxPairsConfig[i].maxPairs;
            if (
                maxPairs == 0 ||
                domain == localDomain ||
                _maxPairsByDomain[domain] != 0
            ) {
                revert InvalidMaxPairsConfig(domain, maxPairs);
            }
            _maxPairsByDomain[domain] = maxPairs;
            emit MaxPairsRegistered(domain, maxPairs);
        }
    }

    /**
     * @notice Circle callback for messages attested at Finalized (2000)
     * @dev Same path as the Unfinalized variant: no finality allowlist
     */
    function handleReceiveFinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 /* finalityThresholdExecuted */,
        bytes calldata messageBody
    ) external override only(TRANSMITTER) returns (bool) {
        _handleCrossChainMessage(sourceDomain, sender, messageBody);
        return true;
    }

    /**
     * @notice Circle callback for messages attested below Finalized (Fast, 1000)
     * @dev Accepted from every configured peer. A revert here reverts the whole
     *      receiveMessage, so the nonce stays unused and the relay can be retried.
     */
    function handleReceiveUnfinalizedMessage(
        uint32 sourceDomain,
        bytes32 sender,
        uint32 /* finalityThresholdExecuted */,
        bytes calldata messageBody
    ) external override only(TRANSMITTER) returns (bool) {
        _handleCrossChainMessage(sourceDomain, sender, messageBody);
        return true;
    }
}
