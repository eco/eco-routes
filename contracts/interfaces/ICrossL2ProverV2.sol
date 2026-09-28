// SPDX-License-Identifier: Apache-2.0
/*
 * Copyright 2024, Polymer Labs
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
pragma solidity ^0.8.2;

/**
 * @title ICrossL2Prover
 * @author Polymer Labs
 * @notice A contract that can prove peptides state. Since peptide is an aggregator of many chains' states, this
 * contract can in turn be used to prove any arbitrary events and/or storage on counterparty chains.
 */
interface ICrossL2ProverV2 {
    /**
     * @notice A a log at a given raw rlp encoded receipt at a given logIndex within the receipt.
     * @notice the receiptRLP should first be validated by calling validateReceipt.
     * @param proof: The proof of a given rlp bytes for the receipt, returned from the receipt MMPT of a block.
     * @return chainId The chainID that the proof proves the log for
     * @return emittingContract The address of the contract that emitted the log on the source chain
     * @return topics The topics of the event. First topic is the event signature that can be calculated by
     * Event.selector. The remaining elements in this array are the indexed parameters of the event.
     * @return unindexedData // The abi encoded non-indexed parameters of the event.
     */
    function validateEvent(
        bytes calldata proof
    )
        external
        view
        returns (
            uint32 chainId,
            address emittingContract,
            bytes calldata topics,
            bytes calldata unindexedData
        );

    // NOT part of Polymer's published ICrossL2ProverV2 as vendored above. Authored for
    // PAR-670 (2026-09) from Polymer's documented Solana log proof interface, targeting the
    // CrossL2ProverV2 on Base mainnet (0x95ccEAE7...) that eco-routes already uses.
    // Selector 0xd73a8ad6 (`cast sig "validateSolLogs(bytes)"`); the selector covers the
    // argument only, so the (uint32,bytes32,string[]) return tuple must be re-verified
    // against the deployed ABI when bumping the Polymer dependency. See .env.example for
    // the pre-deploy probe.
    /**
     * @notice Validates a proof of Solana program logs from Polymer's prove api.
     * @param proof The proof bytes returned by the prove api for a Solana transaction.
     * @return chainId Polymer's identifier for the Solana chain the logs came from
     * @return programID The Solana program (raw 32-byte key) that emitted the logs
     * @return logMessages The proven `Prove:` log lines. Polymer documents that it removes
     *         the `Prove: ` prefix; PolymerProver does not rely on that and parses the line
     *         with or without it.
     */
    function validateSolLogs(
        bytes calldata proof
    )
        external
        view
        returns (
            uint32 chainId,
            bytes32 programID,
            string[] memory logMessages
        );

    /**
     * Return srcChain, Block Number, Receipt Index, and Local Index for a requested proof
     */
    function inspectLogIdentifier(
        bytes calldata proof
    )
        external
        pure
        returns (
            uint32 srcChain,
            uint64 blockNumber,
            uint16 receiptIndex,
            uint8 logIndex
        );

    /**
     * Return polymer state root, height , and signature over height and root which can be verified by
     * crypto.pubkey(keccak(peptideStateRoot, peptideHeight))
     */
    function inspectPolymerState(
        bytes calldata proof
    )
        external
        pure
        returns (bytes32 stateRoot, uint64 height, bytes memory signature);
}
