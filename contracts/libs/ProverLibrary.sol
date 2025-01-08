// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SecureMerkleTrie} from "@eth-optimism/contracts-bedrock/src/libraries/trie/SecureMerkleTrie.sol";
import {RLPReader} from "@eth-optimism/contracts-bedrock/src/libraries/rlp/RLPReader.sol";
import {RLPWriter} from "@eth-optimism/contracts-bedrock/src/libraries/rlp/RLPWriter.sol";

library ProverLibrary {
    uint256 internal constant L2_FAULT_DISPUTE_GAME_ROOT_CLAIM_SLOT =
        0x405787fa12a823e0f2b7631cc41b3ba8828b3321ca811111fa75cd3aa3bb5ad1;

    // Output slot for the game status (aaaaa)
    uint256 internal constant L2_FAULT_DISPUTE_GAME_STATUS_SLOT = 0;

    struct FaultDisputeGameStatusSlotData {
        uint64 createdAt;
        uint64 resolvedAt;
        uint8 gameStatus;
        bool initialized;
        bool l2BlockNumberChallenged;
    }

    struct FaultDisputeGameProofData {
        bytes32 faultDisputeGameStateRoot;
        bytes[] faultDisputeGameRootClaimStorageProof;
        FaultDisputeGameStatusSlotData faultDisputeGameStatusSlotData;
        bytes[] faultDisputeGameStatusStorageProof;
        bytes rlpEncodedFaultDisputeGameData;
        bytes[] faultDisputeGameAccountProof;
    }

    struct DisputeGameFactoryProofData {
        bytes32 messagePasserStateRoot;
        bytes32 latestBlockHash;
        uint256 gameIndex;
        bytes32 gameId;
        bytes[] disputeFaultGameStorageProof;
        bytes rlpEncodedDisputeGameFactoryData;
        bytes[] disputeGameFactoryAccountProof;
    }

    struct ChainConfigurationKey {
        uint256 chainId;
        ProvingMechanism provingMechanism;
    }

    struct ChainConfiguration {
        bool exists;
        uint256 settlementChainId;
        address settlementContract;
        address blockhashOracle;
        uint256 outputRootVersionNumber;
        uint256 provingTimeSeconds;
        uint256 finalityDelaySeconds;
    }

    struct ChainConfigurationConstructor {
        ChainConfigurationKey chainConfigurationKey;
        ChainConfiguration chainConfiguration;
    }

    struct BlockProofKey {
        uint256 chainId;
        SettlementType settlementType;
    }

    struct BlockProof {
        uint256 blockNumber;
        bytes32 blockHash;
        bytes32 stateRoot;
    }

    // The settlement type for the chain
    enum SettlementType {
        Finalized, // Finalized Block information has been posted and resolved on the settlement chain
        Posted, // Settlement Block information has been posted on the settlement chain
        Confirmed // Block is confirmed on the local chain
    }
    // The proving mechanism for the chain
    enum ProvingMechanism {
        Self, // Destination is Self
        Settlement, // Source Chain is an L2, Destination is A L1 Settlement Chain
        SettlementL3, // Source Chain is an L3, Destination is a L2 Settlement Chain
        Bedrock, // Source Chain is an L2, Destination Chain is an L2 using Bedrock
        Cannon, // Source Chain is an L2, Destination Chain is an L2 using Cannon
        HyperProver, //HyperProver
        ArbitrumNitro // Arbitrum Nitro
    }

    /**
     * @notice emitted when Self state is proven
     * @param blockNumber  the block number corresponding to this chains world state
     * @param selfStateRoot the world state root at _blockNumber
     */
    event SelfStateProven(uint256 indexed blockNumber, bytes32 selfStateRoot);

    /**
     * @notice emitted when L1 world state is proven
     * @param blockNumber  the block number corresponding to this L1 world state
     * @param l1WorldStateRoot the world state root at _blockNumber
     */
    event L1WorldStateProven(uint256 indexed blockNumber, bytes32 l1WorldStateRoot);

    /**
     * @notice emitted when L2 world state is proven
     * @param destinationChainID the chainID of the destination chain
     * @param blockNumber the blocknumber corresponding to the world state
     * @param l2WorldStateRoot the world state root at _blockNumber
     */
    event L2WorldStateProven(
        uint256 indexed destinationChainID,
        uint256 indexed blockNumber,
        bytes32 l2WorldStateRoot
    );

    /**
     * @notice emitted on a proving state if the blockNumber is less than or equal to the current blockNumber + SETTLEMENT_BLOCKS_DELAY
     * @param _inputBlockNumber the block number we are trying to prove
     * @param _nextProvableBlockNumber the next block number that can be proven
     */
    error NeedLaterBlock(uint256 _inputBlockNumber, uint256 _nextProvableBlockNumber);

    /**
     * @notice emitted on a proving state if the blockNumber is less than the current blockNumber
     * @param _inputBlockNumber the block number we are trying to prove
     * @param _latestBlockNumber the latest block number that has been proven
     */
    error OutdatedBlock(uint256 _inputBlockNumber, uint256 _latestBlockNumber);

    /**
     * @notice emitted if the passed RLPEncodedBlockData Hash does not match the keccak256 hash of the RPLEncodedData
     * @param _expectedBlockHash the expected block hash for the RLP encoded data
     * @param _calculatedBlockHash the calculated block hash from the RLP encoded data
     */
    error InvalidRLPEncodedBlock(
        bytes32 _expectedBlockHash,
        bytes32 _calculatedBlockHash
    );

    /**
     * @notice emitted on a proving state if the blockNumber is less than the current blockNumber
     * @param _destinationChain the destination chain we are getting settlment chain for
     */
    error NoSettlementChainConfigured(uint256 _destinationChain);

    /**
     * @notice emitted when the destination chain does not support the proving mechanism
     * @param _destinationChain the destination chain
     * @param _provingMechanismRequired the proving mechanism that was required
     */
    error InvalidDestinationProvingMechanism(
        uint256 _destinationChain,
        ProverLibrary.ProvingMechanism _provingMechanismRequired
    );
    /**
     * @notice emitted when proveStorage fails
     * we validate a storage proof  using SecureMerkleTrie.verifyInclusionProof
     * @param _key the key for the storage proof
     * @param _val the _value for the storage proof
     * @param _proof the storage proof
     * @param _root the root
     */
    error InvalidStorageProof(bytes _key, bytes _val, bytes[] _proof, bytes32 _root);

    /**
     * @notice emitted when proveAccount fails
     * we validate account proof  using SecureMerkleTrie.verifyInclusionProof
     * @param _address the address of the data
     * @param _data the data we are validating
     * @param _proof the account proof
     * @param _root the root
     */
    error InvalidAccountProof(bytes _address, bytes _data, bytes[] _proof, bytes32 _root);

    /**
     * @notice emitted when the settlement chain state root has not yet been proven
     * @param _blockProofStateRoot the state root of the block that we are trying to prove
     * @param _l1WorldStateRoot the state root of the last block that was proven on the settlement chain
     */
    error SettlementChainStateRootNotProved(
        bytes32 _blockProofStateRoot,
        bytes32 _l1WorldStateRoot
    );

    /**
     * @notice emitted when the settlement chain state root has not yet been proven
     * @param _blockProofStateRoot the state root of the block that we are trying to prove
     * @param _l2WorldStateRoot the state root of the last block that was proven on the settlement chain
     */
    error DestinationChainStateRootNotProved(
        bytes32 _blockProofStateRoot,
        bytes32 _l2WorldStateRoot
    );

    /**
     * @notice emitted when the settlement chain state root has not yet been proven
     * @param _blockTimeStamp the timestamp of the block that we are trying to prove
     * @param _finalityDelayTimeStamp the time stamp including finality delay that we need to wait for
     */
    error BlockBeforeFinalityPeriod(
        uint256 _blockTimeStamp,
        uint256 _finalityDelayTimeStamp
    );

    /**
     * @notice emitted when we receive an incorrectly encoded contract state root
     * @param _outputOracleStateRoot the state root that was encoded incorrectly
     */
    error IncorrectOutputOracleStateRoot(bytes _outputOracleStateRoot);

    /**
     * @notice emitted when we receive an incorrectly encoded disputeGameFactory state root
     * @param _disputeGameFactoryStateRoot the state root that was encoded incorrectly
     */
    error IncorrectDisputeGameFactoryStateRoot(bytes _disputeGameFactoryStateRoot);

    /**
     * @notice emitted when we receive an incorrectly encoded disputeGameFactory state root
     * @param _inboxStateRoot the state root that was encoded incorrectly
     */
    error IncorrectInboxStateRoot(bytes _inboxStateRoot);

    /**
     * @notice emitted when a fault dispute game has not been resolved
     * @param _gameStatus the status of the fault dispute game (2 is resolved)
     */
    error FaultDisputeGameUnresolved(uint8 _gameStatus);

    /**
     * @notice emitted when we receive an invalid storage proof
     */
    error FailedToProveStorage();

    /**
     * @notice emitted when we receive an invalid Account Proof
     */
    error FailedToProveAccount();

    /**
     * @notice emitted when the Fault Dispute Game is not resolved
     * @param _faultDisputeGameProxyAddress the faultDisputeGames Proxy Address
     */
    error FaultDisputeGameNotResolved(address _faultDisputeGameProxyAddress);

    // Check that the intent has not expired and that the sender is permitted to solve intents
    modifier validRLPEncodeBlock(
        bytes calldata _rlpEncodedBlockData,
        bytes32 _expectedBlockHash
    ) {
        bytes32 calculatedBlockHash = keccak256(_rlpEncodedBlockData);
        if (calculatedBlockHash == _expectedBlockHash) {
            _;
        } else {
            revert InvalidRLPEncodedBlock(_expectedBlockHash, calculatedBlockHash);
        }
    }

    /**
     * @notice validates a storage proof against using SecureMerkleTrie.verifyInclusionProof
     * @param _key key
     * @param _val value
     * @param _proof proof
     * @param _root root
     */
    function proveStorage(
        bytes memory _key,
        bytes memory _val,
        bytes[] memory _proof,
        bytes32 _root
    ) internal pure {
        if (!SecureMerkleTrie.verifyInclusionProof(_key, _val, _proof, _root)) {
            revert InvalidStorageProof(_key, _val, _proof, _root);
        }
    }

    /**
     * @notice validates a storage proof against using SecureMerkleTrie.verifyInclusionProof
     * @param _key key
     * @param _val value
     * @param _proof proof
     * @param _root root
     */
    function proveStorageBytes32(
        bytes memory _key,
        bytes32 _val,
        bytes[] memory _proof,
        bytes32 _root
    ) internal pure {
        // `RLPWriter.writeUint` properly encodes values by removing any leading zeros.
        bytes memory rlpEncodedValue = RLPWriter.writeUint(uint256(_val));
        if (
            !SecureMerkleTrie.verifyInclusionProof(_key, rlpEncodedValue, _proof, _root)
        ) {
            revert InvalidStorageProof(_key, rlpEncodedValue, _proof, _root);
        }
    }

    /**
     * @notice validates an account proof against using SecureMerkleTrie.verifyInclusionProof
     * @param _address address of contract
     * @param _data data
     * @param _proof proof
     * @param _root root
     */
    function proveAccount(
        bytes memory _address,
        bytes memory _data,
        bytes[] memory _proof,
        bytes32 _root
    ) internal pure {
        if (!SecureMerkleTrie.verifyInclusionProof(_address, _data, _proof, _root)) {
            revert InvalidAccountProof(_address, _data, _proof, _root);
        }
    }

    /**
     * @notice generates the output root used for Bedrock and Cannon proving
     * @param outputRootVersion the output root version number usually 0
     * @param worldStateRoot world state root
     * @param messagePasserStateRoot message passer state root
     * @param latestBlockHash latest block hash
     */
    function generateOutputRoot(
        uint256 outputRootVersion,
        bytes32 worldStateRoot,
        bytes32 messagePasserStateRoot,
        bytes32 latestBlockHash
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    outputRootVersion,
                    worldStateRoot,
                    messagePasserStateRoot,
                    latestBlockHash
                )
            );
    }

    /**
     * @notice helper function for getting all rlp data encoded
     * @param dataList list of data elements to be encoded
     */
    function rlpEncodeDataLibList(
        bytes[] memory dataList
    ) internal pure returns (bytes memory) {
        for (uint256 i = 0; i < dataList.length; ++i) {
            dataList[i] = RLPWriter.writeBytes(dataList[i]);
        }

        return RLPWriter.writeList(dataList);
    }

    /**
     * @notice Packs values into a 32 byte GameId type.
     * @param _gameType The game type.
     * @param _timestamp The timestamp of the game's creation.
     * @param _gameProxy The game proxy address.
     * @return gameId_ The packed GameId.
     */
    function pack(
        uint32 _gameType,
        uint64 _timestamp,
        address _gameProxy
    ) internal pure returns (bytes32 gameId_) {
        assembly {
            gameId_ := or(or(shl(224, _gameType), shl(160, _timestamp)), _gameProxy)
        }
    }

    /**
     * @notice Unpacks values from a 32 byte GameId type.
     * @param _gameId The packed GameId.
     * @return gameType_ The game type.
     * @return timestamp_ The timestamp of the game's creation.
     * @return gameProxy_ The game proxy address.
     */
    function unpack(
        bytes32 _gameId
    ) internal pure returns (uint32 gameType_, uint64 timestamp_, address gameProxy_) {
        assembly {
            gameType_ := shr(224, _gameId)
            timestamp_ := and(shr(160, _gameId), 0xFFFFFFFFFFFFFFFF)
            gameProxy_ := and(_gameId, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }
    }

    /**
     * @notice converts bytes to uint
     * @param b bytes to convert
     * @return uint256 converted uint
     */
    function bytesToUint(bytes memory b) internal pure returns (uint256) {
        uint256 number;
        for (uint256 i = 0; i < b.length; i++) {
            number = number + uint256(uint8(b[i])) * (2 ** (8 * (b.length - (i + 1))));
        }
        return number;
    }

    /**
     * @notice assembles the game status storage slot
     * @param createdAt the time the game was created
     * @param resolvedAt the time the game was resolved
     * @param gameStatus the status of the game
     * @param initialized whether the game has been initialized
     * @param l2BlockNumberChallenged whether the l2 block number has been challenged
     * @return gameStatusStorageSlotRLP the game status storage slot in RLP format
     */
    function assembleGameStatusStorage(
        uint64 createdAt,
        uint64 resolvedAt,
        uint8 gameStatus,
        bool initialized,
        bool l2BlockNumberChallenged
    ) internal pure returns (bytes32 gameStatusStorageSlotRLP) {
        // Packed data is 64 + 64 + 8 + 8 + 8 = 152 bits / 19 bytes.
        // Need to convert to `uint152` to preserve right alignment.
        return
            bytes32(
                uint256(
                    uint152(
                        bytes19(
                            abi.encodePacked(
                                l2BlockNumberChallenged,
                                initialized,
                                gameStatus,
                                resolvedAt,
                                createdAt
                            )
                        )
                    )
                )
            );
    }

    function faultDisputeGameIsResolved(
        bytes32 rootClaim,
        address faultDisputeGameProxyAddress,
        FaultDisputeGameProofData memory faultDisputeGameProofData,
        bytes32 l1WorldStateRoot
    ) internal pure {
        if (faultDisputeGameProofData.faultDisputeGameStatusSlotData.gameStatus != 2) {
            revert FaultDisputeGameUnresolved(
                faultDisputeGameProofData.faultDisputeGameStatusSlotData.gameStatus
            );
        } // ensure faultDisputeGame is resolved
        // Prove that the FaultDispute game has been settled
        // storage proof for FaultDisputeGame rootClaim (means block is valid)
        proveStorageBytes32(
            abi.encodePacked(uint256(L2_FAULT_DISPUTE_GAME_ROOT_CLAIM_SLOT)),
            rootClaim,
            faultDisputeGameProofData.faultDisputeGameRootClaimStorageProof,
            bytes32(faultDisputeGameProofData.faultDisputeGameStateRoot)
        );

        bytes32 faultDisputeGameStatusStorage = assembleGameStatusStorage(
            faultDisputeGameProofData.faultDisputeGameStatusSlotData.createdAt,
            faultDisputeGameProofData.faultDisputeGameStatusSlotData.resolvedAt,
            faultDisputeGameProofData.faultDisputeGameStatusSlotData.gameStatus,
            faultDisputeGameProofData.faultDisputeGameStatusSlotData.initialized,
            faultDisputeGameProofData
                .faultDisputeGameStatusSlotData
                .l2BlockNumberChallenged
        );

        // faultDisputeGameProofData.faultDisputeGameStatusSlotData.filler
        // storage proof for FaultDisputeGame status (showing defender won)
        proveStorageBytes32(
            abi.encodePacked(uint256(L2_FAULT_DISPUTE_GAME_STATUS_SLOT)),
            faultDisputeGameStatusStorage,
            faultDisputeGameProofData.faultDisputeGameStatusStorageProof,
            bytes32(
                RLPReader.readBytes(
                    RLPReader.readList(
                        faultDisputeGameProofData.rlpEncodedFaultDisputeGameData
                    )[2]
                )
            )
        );

        // The Account Proof for FaultDisputeGameFactory
        proveAccount(
            abi.encodePacked(faultDisputeGameProxyAddress),
            faultDisputeGameProofData.rlpEncodedFaultDisputeGameData,
            faultDisputeGameProofData.faultDisputeGameAccountProof,
            l1WorldStateRoot
        );
    }

    function getProvenState(
        uint256 chainId,
        ProvingMechanism provingMechanism,
        mapping(uint256 => mapping(ProvingMechanism => ChainConfiguration))
            storage chainConfigurations,
        mapping(uint256 => mapping(SettlementType => BlockProof)) storage provenStates
    )
        internal
        view
        returns (
            ChainConfiguration memory chainConfiguration,
            BlockProofKey memory blockProofKey,
            BlockProof memory blockProof
        )
    {
        if (provingMechanism == ProvingMechanism.Bedrock) {
            chainConfiguration = chainConfigurations[chainId][ProvingMechanism.Bedrock];
            {
                if (chainConfiguration.settlementChainId != block.chainid) {
                    blockProof = provenStates[chainConfiguration.settlementChainId][
                        SettlementType.Finalized
                    ];
                    blockProofKey = BlockProofKey({
                        chainId: chainId,
                        settlementType: SettlementType.Finalized
                    });
                } else {
                    blockProof = provenStates[chainConfiguration.settlementChainId][
                        SettlementType.Confirmed
                    ];
                    blockProofKey = BlockProofKey({
                        chainId: chainId,
                        settlementType: SettlementType.Confirmed
                    });
                }
            }
        }
        return (chainConfiguration, blockProofKey, blockProof);
    }
}
