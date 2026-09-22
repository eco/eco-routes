// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseProver} from "./BaseProver.sol";
import {Semver} from "../libs/Semver.sol";
import {ICrossL2ProverV2} from "../interfaces/ICrossL2ProverV2.sol";
import {AddressConverter} from "../libs/AddressConverter.sol";
import {Whitelist} from "../libs/Whitelist.sol";
import {Base58} from "../libs/Base58.sol";

/**
 * @title PolymerProver
 * @notice Prover implementation using Polymer's cross-chain messaging system
 * @dev Processes proof messages from Polymer's CrossL2ProverV2 and records proven intents.
 *      Two proof shapes are accepted: EVM `IntentFulfilledFromSource` events from whitelisted
 *      EVM PolymerProvers (`validate`), and Solana `Prove:` logs from the whitelisted
 *      eco-routes-svm polymer-prover program (`validateSolana`). The Solana log layout is a
 *      shared ABI with that program's `prove` instruction.
 */
contract PolymerProver is BaseProver, Whitelist, Semver {
    using AddressConverter for bytes32;
    using AddressConverter for address;

    // Constants
    string public constant PROOF_TYPE = "Polymer";
    bytes32 public constant PROOF_SELECTOR =
        keccak256("IntentFulfilledFromSource(uint64,bytes)");
    uint256 public constant EXPECTED_TOPIC_LENGTH = 64; // 2 topics * 32 bytes each
    uint256 public constant MAX_LOG_DATA_SIZE_GUARD = 32 * 1024;

    // Solana log proof constants
    /// @notice Length of the hex payload in a Solana `Prove:` log: 80 bytes = 160 chars
    uint256 public constant SOLANA_LOG_HEX_LENGTH = 160;
    bytes internal constant SOLANA_LOG_PROGRAM_PREFIX = "program: ";
    /// @dev Polymer documents that it strips this from the lines it returns; tolerated if not
    bytes internal constant SOLANA_LOG_PROVE_PREFIX = "Prove:";
    /// @dev What the Solana runtime prepends to every `msg!` line in a transaction log
    bytes internal constant SOLANA_LOG_RUNTIME_PREFIX = "Program log: ";

    // Events
    event IntentFulfilledFromSource(uint64 indexed source, bytes encodedProofs);

    // Errors
    error InvalidEventSignature();
    error InvalidEmittingContract(address emittingContract);
    error InvalidSourceChain();
    error InvalidDestinationChain();
    error InvalidTopicsLength();
    error ZeroAddress();
    error SizeMismatch();
    error MaxDataSizeExceeded();
    error InvalidMaxLogDataSize();
    error EmptyProofData();
    error OnlyPortal();
    error InvalidSolanaProgram(bytes32 programID);
    error InvalidSolanaLog();
    error SolanaLogProgramMismatch();
    error InvalidSolanaChainConfig();
    // Refund of forwarded ETH to the caller failed. PolymerProver does not
    // extend MessageBridgeProver, so this error is declared locally to mirror
    // IMessageBridgeProver.RefundFailed. recipient is always the tx caller.
    error RefundFailed(address recipient, uint256 amount);

    // State variables
    ICrossL2ProverV2 public immutable CROSS_L2_PROVER_V2;
    uint256 public MAX_LOG_DATA_SIZE;
    /// @notice Polymer's identifier for the Solana chain this prover pairs with
    uint32 public immutable SOLANA_POLYMER_CHAIN_ID;
    /// @notice Eco's chain ID for that Solana chain, as recorded in ProofData.destination
    uint64 public immutable SOLANA_CHAIN_ID;

    /**
     * @notice Initializes the PolymerProver contract
     * @param _portal Address of the Portal contract
     * @param _crossL2ProverV2 Address of the CrossL2ProverV2 contract
     * @param _maxLogDataSize Maximum allowed size for encodedProofs in IntentFulfilledFromSource event data
     * @param _solanaPolymerChainId Polymer's chain identifier for Solana (documented as 2)
     * @param _solanaChainId Eco's chain ID for Solana (1399811149 mainnet, 1399811150 devnet)
     * @param _proverAddresses Array of whitelisted prover addresses as bytes32
     *        (EVM prover addresses and the raw 32-byte Solana program ID)
     */
    constructor(
        address _portal,
        address _crossL2ProverV2,
        uint256 _maxLogDataSize,
        uint32 _solanaPolymerChainId,
        uint64 _solanaChainId,
        bytes32[] memory _proverAddresses
    ) BaseProver(_portal) Whitelist(_proverAddresses) {
        if (_crossL2ProverV2 == address(0)) revert ZeroAddress();
        if (_maxLogDataSize == 0 || _maxLogDataSize > MAX_LOG_DATA_SIZE_GUARD) {
            revert InvalidMaxLogDataSize();
        }
        if (_solanaPolymerChainId == 0 || _solanaChainId == 0) {
            revert InvalidSolanaChainConfig();
        }
        MAX_LOG_DATA_SIZE = _maxLogDataSize;
        CROSS_L2_PROVER_V2 = ICrossL2ProverV2(_crossL2ProverV2);
        SOLANA_POLYMER_CHAIN_ID = _solanaPolymerChainId;
        SOLANA_CHAIN_ID = _solanaChainId;
    }

    // ------------- LOG EVENT PROOF VALIDATION -------------

    /**
     * @notice Validates multiple proofs in a batch
     * @dev Atomic: any proof that reverts discards the whole batch; there is no
     *      per-element isolation. A destination-only (zero-pair) element reverts
     *      EmptyProofData and so aborts the batch. An empty array is a no-op.
     * @param proofs Array of proof data to validate
     */
    function validateBatch(bytes[] calldata proofs) external {
        for (uint256 i = 0; i < proofs.length; i++) {
            validate(proofs[i]);
        }
    }

    /**
     * @notice Validates a single proof and processes contained intents
     * @param proof Proof of an IntentFulfilledFromSource event
     */
    function validate(bytes calldata proof) public {
        (
            uint32 destinationChainId,
            address emittingContract,
            bytes memory topics,
            bytes memory data
        ) = CROSS_L2_PROVER_V2.validateEvent(proof);

        if (!isWhitelisted(emittingContract.toBytes32())) {
            revert InvalidEmittingContract(emittingContract);
        }

        if (topics.length != EXPECTED_TOPIC_LENGTH)
            revert InvalidTopicsLength();

        if (data.length == 0) {
            revert EmptyProofData();
        }

        // ABI-decode the unindexedData as per Polymer documentation
        // The data parameter contains ABI-encoded bytes from the event
        bytes memory decodedData = abi.decode(data, (bytes));

        // Fold the length floor into the existing shape check: a payload shorter than the
        // 8-byte destination header would otherwise underflow to Panic(0x11) instead of the
        // declared error. Mirrors ProofData::from_bytes in eco-svm-std, which maps both
        // shape violations to one error.
        if (decodedData.length < 8 || (decodedData.length - 8) % 64 != 0) {
            revert ArrayLengthMismatch();
        }

        bytes32 eventSignature;
        uint64 eventSourceChainId;
        uint64 proofDataChainId;

        assembly {
            let topicsPtr := add(topics, 32)
            let dataPtr := add(decodedData, 32)

            eventSignature := mload(topicsPtr)
            eventSourceChainId := mload(add(topicsPtr, 32))
            proofDataChainId := shr(192, mload(dataPtr)) // Extract first 8 bytes (64 bits) from the 32-byte word
        }

        if (eventSignature != PROOF_SELECTOR) revert InvalidEventSignature();
        if (eventSourceChainId != block.chainid) revert InvalidSourceChain();

        // Verify the chain ID from proof data matches the destination chain from validateEvent
        if (proofDataChainId != uint64(destinationChainId))
            revert InvalidDestinationChain();

        uint256 numPairs = (decodedData.length - 8) / 64;
        // Parity with validateSolana and the SVM validate: a destination-only payload is a
        // malformed proof, not a successful no-op.
        if (numPairs == 0) revert EmptyProofData();
        for (uint256 i = 0; i < numPairs; i++) {
            uint256 offset = 8 + i * 64;

            bytes32 intentHash;
            bytes32 claimantBytes;

            assembly {
                let dataPtr := add(decodedData, 32)
                intentHash := mload(add(dataPtr, offset))
                claimantBytes := mload(add(dataPtr, add(offset, 32)))
            }

            if (claimantBytes >> 160 != 0) continue;

            address claimant = claimantBytes.toAddress();
            processIntent(intentHash, claimant, destinationChainId);
        }
    }

    // ------------- SOLANA LOG PROOF VALIDATION -------------

    /**
     * @notice Validates multiple Solana log proofs in a batch
     * @dev Atomic: any proof that reverts discards the whole batch; there is no
     *      per-element isolation. An empty array is a no-op.
     * @param proofs Array of Solana log proofs to validate
     */
    function validateSolanaBatch(bytes[] calldata proofs) external {
        for (uint256 i = 0; i < proofs.length; i++) {
            validateSolana(proofs[i]);
        }
    }

    /**
     * @notice Validates a Polymer proof of Solana `Prove:` logs emitted by a whitelisted
     *         eco-routes-svm polymer-prover program and records the contained intents
     * @dev Each log line is `program: <base58 program id>, <160 hex chars>` where the hex is
     *      source chain ID (8) ‖ destination chain ID (8) ‖ intent hash (32) ‖ claimant (32).
     *      Polymer authenticates `programID` and `chainId`; the base58 id inside the line is
     *      compared byte-for-byte against the canonical base58 encoding of `programID` as
     *      defense in depth against log misattribution. A program field that is not that
     *      exact string (wrong id, non-base58 chars, over-long, non-canonical leading `1`s)
     *      reverts SolanaLogProgramMismatch; every other malformed line reverts
     *      InvalidSolanaLog. Both fail closed and abort the whole proof.
     *
     *      A Polymer Solana proof is scoped to a whole transaction while `source` is set per
     *      `portal::prove` instruction, so one transaction can legitimately carry `Prove:`
     *      lines for several EVM source chains. Lines whose source is another chain are
     *      skipped rather than reverted, or the proof would be unusable on every chain in it.
     *      At least one line must be for this chain, else InvalidSourceChain, so a proof
     *      submitted to the wrong chain's prover still fails loudly instead of succeeding as
     *      a no-op. Claimants that are not 160-bit EVM addresses, or are zero, are skipped.
     *
     *      Pinned against eco-routes-svm
     *      programs/polymer-prover/src/instructions/prove/testdata/prove_log_line_format.golden
     *      by testValidateSolanaAcceptsSvmGoldenLogLine.
     * @param proof Proof of a Solana transaction's logs from Polymer's prove api
     */
    function validateSolana(bytes calldata proof) public {
        (
            uint32 chainId,
            bytes32 programID,
            string[] memory logMessages
        ) = CROSS_L2_PROVER_V2.validateSolLogs(proof);

        if (chainId != SOLANA_POLYMER_CHAIN_ID)
            revert InvalidDestinationChain();
        if (!isWhitelisted(programID)) revert InvalidSolanaProgram(programID);
        if (logMessages.length == 0) revert EmptyProofData();

        // canonical base58 of the authenticated program id, hashed once for the loop
        bytes32 expectedProgramStrHash = keccak256(
            bytes(Base58.encode(abi.encodePacked(programID)))
        );

        uint256 matched = 0;
        for (uint256 i = 0; i < logMessages.length; i++) {
            if (
                _processSolanaLog(bytes(logMessages[i]), expectedProgramStrHash)
            ) {
                matched++;
            }
        }
        if (matched == 0) revert InvalidSourceChain();
    }

    /**
     * @notice Parses one proven Solana log line and records its intent
     * @dev The head tolerates, in this order, the Solana runtime `Program log: ` prefix and
     *      Polymer's `Prove:` prefix, each optional and each followed by any number of
     *      spaces, before the required `program: `. Polymer documents that it strips
     *      `Prove: ` from the lines it returns; that is unverified against the deployed
     *      indexer, and the tolerance is confined to the head. The `, <hex>` tail is
     *      byte-exact: exactly SOLANA_LOG_HEX_LENGTH hex chars and nothing after them.
     * @param log The log line, with or without the Solana runtime `Program log: ` and/or
     *        Polymer's `Prove:` prefix
     * @param expectedProgramStrHash keccak256 of the canonical base58 encoding of the
     *        authenticated emitting program
     * @return ours True when the line is for this chain (recorded, or skipped only because
     *         its claimant is not an EVM address); false when its source is another chain
     */
    function _processSolanaLog(
        bytes memory log,
        bytes32 expectedProgramStrHash
    ) internal returns (bool ours) {
        uint256 cursor = _skipSpaces(log, 0);
        if (_startsWithAt(log, SOLANA_LOG_RUNTIME_PREFIX, cursor)) {
            cursor = _skipSpaces(
                log,
                cursor + SOLANA_LOG_RUNTIME_PREFIX.length
            );
        }
        if (_startsWithAt(log, SOLANA_LOG_PROVE_PREFIX, cursor)) {
            cursor = _skipSpaces(log, cursor + SOLANA_LOG_PROVE_PREFIX.length);
        }
        if (!_startsWithAt(log, SOLANA_LOG_PROGRAM_PREFIX, cursor)) {
            revert InvalidSolanaLog();
        }
        cursor += SOLANA_LOG_PROGRAM_PREFIX.length;

        // program id runs up to ", "
        uint256 comma = cursor;
        while (comma < log.length && log[comma] != ",") {
            comma++;
        }
        // need ", " plus exactly the hex payload, and nothing after it
        if (
            comma + 2 + SOLANA_LOG_HEX_LENGTH != log.length ||
            log[comma + 1] != " "
        ) {
            revert InvalidSolanaLog();
        }

        bytes memory programStr = new bytes(comma - cursor);
        for (uint256 i = 0; i < programStr.length; i++) {
            programStr[i] = log[cursor + i];
        }
        if (keccak256(programStr) != expectedProgramStrHash) {
            revert SolanaLogProgramMismatch();
        }

        bytes memory payload = _hexDecode(log, comma + 2);

        uint64 source = uint64(bytes8(_slice32(payload, 0)));
        uint64 destination = uint64(bytes8(_slice32(payload, 8)));
        bytes32 intentHash = _slice32(payload, 16);
        bytes32 claimantBytes = _slice32(payload, 48);

        // Checked before the source filter: every line from this one program carries
        // the same hard-coded CHAIN_ID, so a mismatch is a bug or misattribution on
        // any line, whatever its source.
        if (destination != SOLANA_CHAIN_ID) revert InvalidDestinationChain();
        // Full-width comparison like the EVM path: `source` widens to uint256, so a
        // chain whose id exceeds 2^64-1 (which the 8-byte field cannot encode) fails
        // closed instead of matching mod 2^64.
        if (source != block.chainid) return false;
        // Ours, but the claimant is not an EVM address. Must run before toAddress.
        if (claimantBytes >> 160 != 0) return true;

        processIntent(intentHash, claimantBytes.toAddress(), destination);
        return true;
    }

    /// @dev Index of the first non-space byte at or after `at`, or `log.length`
    function _skipSpaces(
        bytes memory log,
        uint256 at
    ) internal pure returns (uint256) {
        while (at < log.length && log[at] == " ") {
            at++;
        }
        return at;
    }

    /// @dev True when `haystack[at..]` begins with `needle`
    function _startsWithAt(
        bytes memory haystack,
        bytes memory needle,
        uint256 at
    ) internal pure returns (bool) {
        if (haystack.length < at + needle.length) return false;
        for (uint256 i = 0; i < needle.length; i++) {
            if (haystack[at + i] != needle[i]) return false;
        }
        return true;
    }

    /// @dev Reads 32 bytes of `data` starting at `offset` (caller guarantees bounds)
    function _slice32(
        bytes memory data,
        uint256 offset
    ) internal pure returns (bytes32 out) {
        assembly {
            out := mload(add(add(data, 0x20), offset))
        }
    }

    /**
     * @dev Decodes SOLANA_LOG_HEX_LENGTH hex chars of `src` starting at `start` into 80
     *      bytes. The emitter (eco-routes-svm prove.rs) always produces lowercase, per the
     *      spec's "160 lowercase hex chars"; uppercase is accepted defensively. Reverts
     *      InvalidSolanaLog on a non-hex char.
     */
    function _hexDecode(
        bytes memory src,
        uint256 start
    ) internal pure returns (bytes memory out) {
        out = new bytes(SOLANA_LOG_HEX_LENGTH / 2);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = bytes1(
                (_nibble(src[start + 2 * i]) << 4) |
                    _nibble(src[start + 2 * i + 1])
            );
        }
    }

    /// @dev Value of one hex digit; reverts InvalidSolanaLog on anything else
    function _nibble(bytes1 c) internal pure returns (uint8) {
        uint8 v = uint8(c);
        if (v >= 0x30 && v <= 0x39) return v - 0x30; // 0-9
        if (v >= 0x61 && v <= 0x66) return v - 0x61 + 10; // a-f
        if (v >= 0x41 && v <= 0x46) return v - 0x41 + 10; // A-F
        revert InvalidSolanaLog();
    }

    // ------------- INTERNAL FUNCTIONS - INTENT PROCESSING -------------

    /**
     * @notice Processes a single intent proof
     * @dev Shared sink for `validate` and `validateSolana`. Both callers already skip
     *      claimants that are not 160-bit EVM addresses; a zero claimant is skipped here.
     * @param intentHash Hash of the intent being proven
     * @param claimant Address that fulfilled the intent and should receive rewards
     * @param destination Destination chain ID for the intent
     */
    function processIntent(
        bytes32 intentHash,
        address claimant,
        uint64 destination
    ) internal {
        // Parity with BaseProver._processIntentProofs: a zero claimant is the
        // "unproven" sentinel for this slot, so recording one would emit a phantom
        // IntentProven over a slot that still reads as empty, and one that
        // challengeIntentProof (which also gates on a non-zero claimant) cannot clear.
        if (claimant == address(0)) return;

        ProofData storage proof = _provenIntents[intentHash];
        if (proof.claimant != address(0)) {
            emit IntentAlreadyProven(intentHash);

            return;
        }
        proof.claimant = claimant;
        proof.destination = destination;

        emit IntentProven(intentHash, claimant, destination);
    }

    // ------------- INTERFACE IMPLEMENTATION -------------

    /**
     * @notice Returns the proof type used by this prover
     * @dev Implementation of IProver interface method
     * @return string The type of proof mechanism (Polymer)
     */
    function getProofType() external pure override returns (string memory) {
        return PROOF_TYPE;
    }

    // ------------ EXTERNAL PROVE FUNCTION -------------

    /**
     * @notice Emits IntentFulfilledFromSource events that can be proven by Polymer
     * @dev Only callable by the Portal contract
     * @param sender Address that initiated the proving request and should receive
     *        any forwarded ETH refund (Polymer proving requires no fee)
     * @param sourceChainDomainID Domain ID of the source chain (treated as chain ID for Polymer)
     * @param encodedProofs Encoded (intentHash, claimant) pairs as bytes
     */
    function prove(
        address sender,
        uint64 sourceChainDomainID,
        bytes calldata encodedProofs,
        bytes calldata /* unused */
    ) external payable {
        if (msg.sender != PORTAL) revert OnlyPortal();
        if (encodedProofs.length > MAX_LOG_DATA_SIZE) {
            revert MaxDataSizeExceeded();
        }

        emit IntentFulfilledFromSource(sourceChainDomainID, encodedProofs);

        // Polymer proving requires no bridge fee, so any forwarded ETH (forced
        // dust or overpayment from Inbox.prove routing the Portal balance here)
        // is refunded to the caller. A low-level call forwarding all gas is used
        // (not transfer()'s 2300-gas cap) so any smart-contract recipient — a
        // smart account or EIP-7702 wallet whose receive() needs more than the
        // stipend — can still receive the refund.
        //
        // On failure we revert (RefundFailed) rather than swallow the boolean,
        // surfacing a genuinely-unpayable recipient loudly instead of silently
        // stranding the ETH as dust (there is no sweep path). The recipient is
        // always the tx caller, so a revert only self-DoSes that caller — no
        // third-party griefing. This is the terminal statement (no post-refund
        // state) and Inbox.prove has already drained the Portal balance, so the
        // all-gas call cannot be exploited via reentrancy.
        if (msg.value > 0 && sender != address(0)) {
            (bool ok, ) = payable(sender).call{value: msg.value}("");
            if (!ok) revert RefundFailed(sender, msg.value);
        }
    }
}
