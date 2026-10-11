// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ILayerZeroReceiver} from "../interfaces/layerzero/ILayerZeroReceiver.sol";
import {ILayerZeroEndpointV2} from "../interfaces/layerzero/ILayerZeroEndpointV2.sol";
import {MessageBridgeProver} from "./MessageBridgeProver.sol";
import {Semver} from "../libs/Semver.sol";

/**
 * @title LayerZeroProver
 * @notice Prover implementation using LayerZero's cross-chain messaging system
 * @dev Processes proof messages from LayerZero endpoint and records proven intents.
 *      Born locked: the constructor pins the send/receive library, executor and
 *      ULN (DVNs, confirmations) of every pathway in the domain map, then makes
 *      the prover its own endpoint delegate. No account ever holds configuration
 *      rights, so no pathway can be changed or fall back to LayerZero's mutable
 *      defaults after deployment. A different config needs a new deployment.
 */
contract LayerZeroProver is ILayerZeroReceiver, MessageBridgeProver, Semver {
    using SafeCast for uint256;
    /**
     * @notice Struct for unpacked data from _data parameter
     * @dev Contains fields decoded from the _data parameter
     */
    struct UnpackedData {
        bytes32 sourceChainProver; // Address of prover on source chain
        uint128 gasLimit; // Gas limit for execution
    }

    /**
     * @notice Constant indicating this contract uses LayerZero for proving
     */
    string public constant PROOF_TYPE = "LayerZero";

    /**
     * @notice Pathway security pinned on every domain of the domain map
     * @param sendLibrary Send library (SendUln302) for every remote eid
     * @param receiveLibrary Receive library (ReceiveUln302) for every remote eid
     * @param executor Executor paid to deliver outbound messages
     * @param maxMessageSizes Largest outbound message the executor accepts, per
     *        destination, parallel to domainConfig: a non-EVM receiver (Solana)
     *        can process far fewer proofs per message than an EVM one
     * @param requiredDVNs DVNs that must all verify, strictly ascending
     * @param sendConfirmations Block confirmations DVNs wait for on this chain
     * @param receiveConfirmations Confirmations per origin, parallel to domainConfig
     */
    struct LayerZeroConfig {
        address sendLibrary;
        address receiveLibrary;
        address executor;
        uint32[] maxMessageSizes;
        address[] requiredDVNs;
        uint64 sendConfirmations;
        uint64[] receiveConfirmations;
    }

    /**
     * @notice ULN302 ULN config (CONFIG_TYPE_ULN), mirrored for encoding
     */
    struct UlnConfig {
        uint64 confirmations;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
        uint8 optionalDVNThreshold;
        address[] requiredDVNs;
        address[] optionalDVNs;
    }

    /**
     * @notice ULN302 executor config (CONFIG_TYPE_EXECUTOR), mirrored for encoding
     */
    struct ExecutorConfig {
        uint32 maxMessageSize;
        address executor;
    }

    /**
     * @notice ULN302 config type of ExecutorConfig
     */
    uint32 internal constant CONFIG_TYPE_EXECUTOR = 1;

    /**
     * @notice ULN302 config type of UlnConfig
     */
    uint32 internal constant CONFIG_TYPE_ULN = 2;

    /**
     * @notice ULN302's "no optional DVNs" count; 0 would inherit the default ones
     */
    uint8 internal constant NIL_DVN_COUNT = type(uint8).max;

    /**
     * @notice ULN302's largest DVN count, (type(uint8).max - 1) / 2
     */
    uint256 internal constant MAX_DVN_COUNT = 127;

    /**
     * @notice ULN302's "zero confirmations" value, which skips the pinned count
     */
    uint64 internal constant NIL_CONFIRMATIONS = type(uint64).max;

    /**
     * @notice Additional gas allocated per intent in the batch.
     * @dev Derived from worst-case measured cost of a cold SSTORE + event emission
     *      in _processIntentProofs (~25k measured), doubled for safety margin.
     *      The total gas floor for a batch is MIN_GAS_LIMIT + n * GAS_PER_INTENT.
     */
    uint256 public constant GAS_PER_INTENT = 50_000;

    /**
     * @notice Address of local LayerZero endpoint
     */
    address public immutable ENDPOINT;

    /**
     * @notice LayerZero endpoint address cannot be zero
     */
    error EndpointCannotBeZeroAddress();

    /**
     * @notice A send or receive library cannot be zero
     */
    error LibraryCannotBeZeroAddress();

    /**
     * @notice Executor must be set; ULN302 reads 0 as the default executor
     */
    error InvalidExecutorConfig();

    /**
     * @notice A maxMessageSize must be set; ULN302 reads 0 as the default
     * @param domain The destination domain the value was given for
     */
    error InvalidMaxMessageSize(uint64 domain);

    /**
     * @notice maxMessageSizes must have one entry per domainConfig entry
     * @param expected domainConfig length
     * @param actual maxMessageSizes length
     */
    error MaxMessageSizesLengthMismatch(uint256 expected, uint256 actual);

    /**
     * @notice Required DVN count must be 1..127; ULN302 reads 0 as the default DVNs
     * @param count The rejected count
     */
    error InvalidRequiredDVNCount(uint256 count);

    /**
     * @notice Send confirmations must be pinned (not 0 = default, not NIL)
     * @param confirmations The rejected value
     */
    error InvalidSendConfirmations(uint64 confirmations);

    /**
     * @notice Receive confirmations must be pinned (not 0 = default, not NIL)
     * @param domain The origin domain the value was given for
     * @param confirmations The rejected value
     */
    error InvalidReceiveConfirmations(uint64 domain, uint64 confirmations);

    /**
     * @notice receiveConfirmations must have one entry per domainConfig entry
     * @param expected domainConfig length
     * @param actual receiveConfirmations length
     */
    error ReceiveConfirmationsLengthMismatch(uint256 expected, uint256 actual);

    /**
     * @param endpoint Address of local LayerZero endpoint
     * @param portal Address of Portal contract
     * @param provers Array of trusted prover addresses (as bytes32 for cross-VM compatibility)
     * @param minGasLimit Minimum gas limit for cross-chain messages (200k if zero)
     * @param domainConfig Trusted origin-domain-to-chainId mapping entries; each
     *        domain is a LayerZero eid and gets one pinned pathway
     * @param lzConfig Pathway security pinned on every domain
     */
    constructor(
        address endpoint,
        address portal,
        bytes32[] memory provers,
        uint256 minGasLimit,
        Domain[] memory domainConfig,
        LayerZeroConfig memory lzConfig
    ) MessageBridgeProver(portal, provers, minGasLimit, domainConfig) {
        if (endpoint == address(0)) revert EndpointCannotBeZeroAddress();

        // Store the LayerZero endpoint address for future reference
        ENDPOINT = endpoint;

        _pinPathways(ILayerZeroEndpointV2(endpoint), domainConfig, lzConfig);

        // Lock: the prover is its own delegate and has no function that calls
        // the endpoint's admin surface (setConfig, set*Library, skip, clear,
        // nilify, burn), so nothing can ever change a pathway again.
        ILayerZeroEndpointV2(endpoint).setDelegate(address(this));
    }

    /**
     * @notice Pins libraries, executor and ULN on every domain, as the OApp
     * @dev Runs inside the constructor: the endpoint authorizes msg.sender == oapp,
     *      and calls back into nothing, so a contract without code yet qualifies.
     *      Every value is explicit: ULN302 reads 0 in the DVN count, confirmations,
     *      executor or maxMessageSize as "use LayerZero's default", which LayerZero
     *      can change later. Optional DVNs are NIL (255), never 0, for the same
     *      reason. ULN302 itself rejects unsorted or duplicate DVNs.
     * @param endpoint The local EndpointV2
     * @param domainConfig Domain map; each domain is a remote eid
     * @param lzConfig Pathway security to pin
     */
    function _pinPathways(
        ILayerZeroEndpointV2 endpoint,
        Domain[] memory domainConfig,
        LayerZeroConfig memory lzConfig
    ) internal {
        _validateLayerZeroConfig(domainConfig, lzConfig);

        for (uint256 i = 0; i < domainConfig.length; ++i) {
            uint32 eid = uint256(domainConfig[i].domain).toUint32();
            endpoint.setSendLibrary(address(this), eid, lzConfig.sendLibrary);
            // Grace 0: the previous library is the default, and a non-zero
            // grace on a default library reverts (LZ_OnlyNonDefaultLib).
            endpoint.setReceiveLibrary(
                address(this),
                eid,
                lzConfig.receiveLibrary,
                0
            );
        }

        (
            ILayerZeroEndpointV2.SetConfigParam[] memory sendParams,
            ILayerZeroEndpointV2.SetConfigParam[] memory receiveParams
        ) = _configParams(domainConfig, lzConfig);
        endpoint.setConfig(address(this), lzConfig.sendLibrary, sendParams);
        endpoint.setConfig(
            address(this),
            lzConfig.receiveLibrary,
            receiveParams
        );
    }

    /**
     * @notice Rejects any value ULN302 would read as "use LayerZero's default"
     * @param domainConfig Domain map; receiveConfirmations is parallel to it
     * @param lzConfig Pathway security to check
     */
    function _validateLayerZeroConfig(
        Domain[] memory domainConfig,
        LayerZeroConfig memory lzConfig
    ) internal pure {
        if (
            lzConfig.sendLibrary == address(0) ||
            lzConfig.receiveLibrary == address(0)
        ) revert LibraryCannotBeZeroAddress();
        if (lzConfig.executor == address(0)) revert InvalidExecutorConfig();
        uint256 dvnCount = lzConfig.requiredDVNs.length;
        if (dvnCount == 0 || dvnCount > MAX_DVN_COUNT) {
            revert InvalidRequiredDVNCount(dvnCount);
        }
        if (!_isPinned(lzConfig.sendConfirmations)) {
            revert InvalidSendConfirmations(lzConfig.sendConfirmations);
        }
        if (lzConfig.receiveConfirmations.length != domainConfig.length) {
            revert ReceiveConfirmationsLengthMismatch(
                domainConfig.length,
                lzConfig.receiveConfirmations.length
            );
        }
        if (lzConfig.maxMessageSizes.length != domainConfig.length) {
            revert MaxMessageSizesLengthMismatch(
                domainConfig.length,
                lzConfig.maxMessageSizes.length
            );
        }
        for (uint256 i = 0; i < domainConfig.length; ++i) {
            if (!_isPinned(lzConfig.receiveConfirmations[i])) {
                revert InvalidReceiveConfirmations(
                    domainConfig[i].domain,
                    lzConfig.receiveConfirmations[i]
                );
            }
            if (lzConfig.maxMessageSizes[i] == 0) {
                revert InvalidMaxMessageSize(domainConfig[i].domain);
            }
        }
    }

    /**
     * @notice The setConfig entries for both libraries
     * @dev Send library: executor with the destination's message cap + ULN with
     *      this chain's confirmations, per eid.
     *      Receive library: ULN with the origin's confirmations, per eid.
     * @param domainConfig Domain map; each domain is a remote eid
     * @param lzConfig Validated pathway security
     * @return sendParams Entries for the send library
     * @return receiveParams Entries for the receive library
     */
    function _configParams(
        Domain[] memory domainConfig,
        LayerZeroConfig memory lzConfig
    )
        internal
        pure
        returns (
            ILayerZeroEndpointV2.SetConfigParam[] memory sendParams,
            ILayerZeroEndpointV2.SetConfigParam[] memory receiveParams
        )
    {
        uint256 count = domainConfig.length;
        bytes memory sendUln = _encodeUln(
            lzConfig.sendConfirmations,
            lzConfig.requiredDVNs
        );
        sendParams = new ILayerZeroEndpointV2.SetConfigParam[](2 * count);
        receiveParams = new ILayerZeroEndpointV2.SetConfigParam[](count);

        for (uint256 i = 0; i < count; ++i) {
            uint32 eid = uint256(domainConfig[i].domain).toUint32();
            sendParams[2 * i] = ILayerZeroEndpointV2.SetConfigParam(
                eid,
                CONFIG_TYPE_EXECUTOR,
                abi.encode(
                    ExecutorConfig(
                        lzConfig.maxMessageSizes[i],
                        lzConfig.executor
                    )
                )
            );
            sendParams[2 * i + 1] = ILayerZeroEndpointV2.SetConfigParam(
                eid,
                CONFIG_TYPE_ULN,
                sendUln
            );
            receiveParams[i] = ILayerZeroEndpointV2.SetConfigParam(
                eid,
                CONFIG_TYPE_ULN,
                _encodeUln(
                    lzConfig.receiveConfirmations[i],
                    lzConfig.requiredDVNs
                )
            );
        }
    }

    /**
     * @notice ULN config with every required DVN and no optional DVNs
     * @param confirmations Block confirmations to pin
     * @param requiredDVNs Required DVNs, strictly ascending
     * @return ABI-encoded UlnConfig
     */
    function _encodeUln(
        uint64 confirmations,
        address[] memory requiredDVNs
    ) internal pure returns (bytes memory) {
        return
            abi.encode(
                UlnConfig({
                    confirmations: confirmations,
                    requiredDVNCount: uint8(requiredDVNs.length),
                    optionalDVNCount: NIL_DVN_COUNT,
                    optionalDVNThreshold: 0,
                    requiredDVNs: requiredDVNs,
                    optionalDVNs: new address[](0)
                })
            );
    }

    /**
     * @notice Whether a confirmations value is an explicit block count
     * @param confirmations Value to check
     * @return False for 0 (inherits the default) and NIL (zero blocks)
     */
    function _isPinned(uint64 confirmations) internal pure returns (bool) {
        return confirmations != 0 && confirmations != NIL_CONFIRMATIONS;
    }

    /**
     * @notice Handles incoming LayerZero messages containing proof data
     * @dev Processes batch updates to proven intents from valid sources
     * @param origin Origin information containing source endpoint and sender
     * param guid Unique identifier for the message (not used here)
     * @param message Encoded array of intent hashes and claimants
     * param executor Address of the executor (should be endpoint or zero)
     * param extraData Additional data for message processing (not used here)
     */
    function lzReceive(
        Origin calldata origin,
        bytes32 /* guid */,
        bytes calldata message,
        address /* executor */,
        bytes calldata /* extraData */
    ) external payable override only(ENDPOINT) {
        // Validate sender is not zero
        if (origin.sender == bytes32(0)) {
            revert MessageSenderCannotBeZeroAddress();
        }

        _handleCrossChainMessage(uint64(origin.srcEid), origin.sender, message);
    }

    /**
     * @notice Check if path is allowed for receiving messages
     * @param origin Origin information to check
     * @return Whether the origin is allowed
     */
    function allowInitializePath(
        Origin calldata origin
    ) external view override returns (bool) {
        return
            isWhitelisted(origin.sender) &&
            _chainIdByDomain[origin.srcEid] != 0;
    }

    /**
     * @notice Get next expected nonce from a source
     * @dev Always returns 0 as we don't track nonces
     * @return Always returns 0 as we don't track nonces
     */
    // Nonce tracking intentionally disabled; replay is prevented by the already-proven skip in _processIntentProofs.
    function nextNonce(
        uint32 /* srcEid */,
        bytes32 /* sender */
    ) external pure override returns (uint64) {
        // We don't track nonces, return 0
        return 0;
    }

    /**
     * @notice Implementation of message dispatch for LayerZero
     * @dev Called by base prove() function after common validations
     * @param domainID Domain ID of the source chain
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     * @param data Additional data for message formatting
     * @param fee Fee amount for message dispatch
     */
    function _dispatchMessage(
        uint64 domainID,
        bytes calldata encodedProofs,
        bytes calldata data,
        uint256 fee
    ) internal override {
        // Parse incoming data into a structured format
        UnpackedData memory unpacked = _unpackData(data);

        // Create messaging parameters for LayerZero
        ILayerZeroEndpointV2.MessagingParams
            memory params = _formatLayerZeroMessage(
                domainID,
                encodedProofs,
                unpacked
            );

        // Send the message through LayerZero endpoint
        // solhint-disable-next-line check-send-result
        ILayerZeroEndpointV2(ENDPOINT).send{value: fee}(
            params,
            msg.sender // refund address
        );
    }

    /**
     * @notice Calculates the fee required for LayerZero message dispatch
     * @dev Queries the Endpoint contract for accurate fee estimation
     * @param domainID Domain ID of the source chain
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     * @param data Additional data for message formatting
     * @return Fee amount required for message dispatch
     */
    function fetchFee(
        uint64 domainID,
        bytes calldata encodedProofs,
        bytes calldata data
    ) public view override returns (uint256) {
        // Decode structured data from the raw input
        UnpackedData memory unpacked = _unpackData(data);

        // Process fee calculation using the decoded struct
        return _fetchFee(domainID, encodedProofs, unpacked);
    }

    /**
     * @notice Decodes the raw cross-chain message data into a structured format
     * @dev Parses ABI-encoded parameters into the UnpackedData struct. The gas limit
     *      is used as a caller-supplied floor; the actual gas used for the LZ message
     *      is max(gasLimit, MIN_GAS_LIMIT + n * GAS_PER_INTENT) computed in
     *      _formatLayerZeroMessage, so underfunding is not possible regardless of the
     *      value supplied here.
     * @param data Raw message data containing source chain information
     * @return unpacked Structured representation of the decoded parameters
     */
    function _unpackData(
        bytes calldata data
    ) internal pure returns (UnpackedData memory unpacked) {
        unpacked = abi.decode(data, (UnpackedData));
    }

    /**
     * @notice Internal function to calculate the fee with pre-decoded data
     * @param domainID Domain ID of the source chain
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     * @param unpacked Struct containing decoded data from data parameter
     * @return Fee amount required for message dispatch
     */
    function _fetchFee(
        uint64 domainID,
        bytes calldata encodedProofs,
        UnpackedData memory unpacked
    ) internal view returns (uint256) {
        // Create messaging parameters for LayerZero
        ILayerZeroEndpointV2.MessagingParams
            memory params = _formatLayerZeroMessage(
                domainID,
                encodedProofs,
                unpacked
            );

        // Query LayerZero endpoint for accurate fee estimate
        ILayerZeroEndpointV2.MessagingFee memory fee = ILayerZeroEndpointV2(
            ENDPOINT
        ).quote(params, address(this));

        return fee.nativeFee;
    }

    /**
     * @notice Returns the proof type used by this prover
     * @return ProofType indicating LayerZero proving mechanism
     */
    function getProofType() external pure override returns (string memory) {
        return PROOF_TYPE;
    }

    /**
     * @notice Formats data for LayerZero message dispatch with encoded proofs
     * @dev Prepares all parameters needed for the Endpoint send call.
     *      The gas supplied to the destination executor is always at least
     *      MIN_GAS_LIMIT + numIntents * GAS_PER_INTENT, ensuring lzReceive
     *      cannot OOG regardless of batch size. The caller's gasLimit is used
     *      only if it exceeds this floor.
     * @param domainID Domain ID of the source chain
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     * @param unpacked Struct containing decoded data from data parameter
     * @return params Structured dispatch parameters for LayerZero message
     */
    function _formatLayerZeroMessage(
        uint64 domainID,
        bytes calldata encodedProofs,
        UnpackedData memory unpacked
    )
        internal
        view
        returns (ILayerZeroEndpointV2.MessagingParams memory params)
    {
        // Use domain ID directly as endpoint ID with overflow check
        if (domainID > type(uint32).max) {
            revert DomainIdTooLarge(domainID);
        }
        params.dstEid = uint32(domainID);

        // Use the source chain prover address as the message recipient
        params.receiver = unpacked.sourceChainProver;

        params.message = encodedProofs;

        // Compute a gas floor proportional to the number of intents in the batch.
        // Each intent requires a cold SSTORE + event emission in _processIntentProofs.
        // The 8-byte header is subtracted before dividing by 64 (bytes per intent pair).
        uint256 numIntents = encodedProofs.length > 8
            ? (encodedProofs.length - 8) / 64
            : 0;
        uint128 gasFloor = (MIN_GAS_LIMIT + numIntents * GAS_PER_INTENT)
            .toUint128();
        uint128 gasToUse = unpacked.gasLimit > gasFloor
            ? unpacked.gasLimit
            : gasFloor;

        // LZ V2 type-3 executor option (22 bytes):
        //   uint16(3)    — options format version (type 3)
        //   uint8(1)     — worker ID: executor
        //   uint16(17)   — option data length: 1 (option type byte) + 16 (uint128 gas)
        //   uint8(1)     — executor option type: lzReceive gas
        //   uint128(gas) — gas forwarded to lzReceive on the destination chain
        params.options = abi.encodePacked(
            uint16(3), // options version: type 3
            uint8(1), // worker: executor
            uint16(17), // data length: 1 + 16 bytes
            uint8(1), // executor option: lzReceive
            gasToUse // already uint128
        );
        params.payInLzToken = false;
    }
}
