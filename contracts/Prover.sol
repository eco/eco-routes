// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SecureMerkleTrie} from "@eth-optimism/contracts-bedrock/src/libraries/trie/SecureMerkleTrie.sol";
import {RLPReader} from "@eth-optimism/contracts-bedrock/src/libraries/rlp/RLPReader.sol";
import {RLPWriter} from "@eth-optimism/contracts-bedrock/src/libraries/rlp/RLPWriter.sol";
import {IL1Block} from "./interfaces/IL1Block.sol";
import {SimpleProver} from "./interfaces/SimpleProver.sol";
import {Semver} from "./libs/Semver.sol";

contract Prover is SimpleProver {
    ProofType public constant PROOF_TYPE = ProofType.Storage;

    // Output slot for Bedrock L2_OUTPUT_ORACLE where Settled Batches are stored
    uint256 public constant L2_OUTPUT_SLOT_NUMBER = 3;

    uint256 public constant L2_OUTPUT_ROOT_VERSION_NUMBER = 0;

    // L2OutputOracle on Ethereum used for Bedrock (Base) Proving
    // address public immutable l1OutputOracleAddress;

    // Cannon Data
    // FaultGameFactory on Ethereum used for Cannon (Optimism) Proving
    // address public immutable faultGameFactoryAddress;

    // Output slot for Cannon DisputeGameFactory where FaultDisputeGames gameId's are stored
    uint256 public constant L2_DISPUTE_GAME_FACTORY_LIST_SLOT_NUMBER = 104;

    // Output slot for the root claim (used as the block number settled is part of the root claim)
    uint256 public constant L2_FAULT_DISPUTE_GAME_ROOT_CLAIM_SLOT =
        0x405787fa12a823e0f2b7631cc41b3ba8828b3321ca811111fa75cd3aa3bb5ad1;

    // Output slot for the game status (fixed)
    uint256 public constant L2_FAULT_DISPUTE_GAME_STATUS_SLOT = 0;

    // Number of blocks to wait before Settlement Layer can be proven again
    uint256 public immutable SETTLEMENT_BLOCKS_DELAY;

    // This contract lives on an L2 and contains the data for the 'current' L1 block.
    // there is a delay between this contract and L1 state - the block information found here is usually a few blocks behind the most recent block on L1.
    // But optimism maintains a service that posts L1 block data on L2.
    IL1Block public l1BlockhashOracle;

    struct ChainConfiguration {
        uint8 provingMechanism;
        uint256 settlementChainId;
        address settlementContract;
        address blockhashOracle;
        uint256 outputRootVersionNumber;
        uint256 finalityDelaySeconds;
    }

    struct ChainConfigurationConstructor {
        uint256 chainId;
        ChainConfiguration chainConfiguration;
    }

    // map the chain id to chain configuration
    mapping(uint256 => ChainConfiguration) public chainConfigurations;

    struct BlockProof {
        uint256 blockNumber;
        bytes32 blockHash;
        bytes32 stateRoot;
    }

    // Store the last BlockProof for each ChainId
    mapping(uint256 => BlockProof) public provenStates;

    struct DisputeGameFactoryProofData {
        bytes32 messagePasserStateRoot;
        bytes32 latestBlockHash;
        uint256 gameIndex;
        bytes32 gameId;
        bytes[] disputeFaultGameStorageProof;
        bytes rlpEncodedDisputeGameFactoryData;
        bytes[] disputeGameFactoryAccountProof;
    }

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

    /**
     * @notice emitted when L1 world state is proven
     * @param _blockNumber  the block number corresponding to this L1 world state
     * @param _L1WorldStateRoot the world state root at _blockNumber
     */
    event L1WorldStateProven(uint256 indexed _blockNumber, bytes32 _L1WorldStateRoot);

    /**
     * @notice emitted when L2 world state is proven
     * @param _destinationChainID the chainID of the destination chain
     * @param _blockNumber the blocknumber corresponding to the world state
     * @param _L2WorldStateRoot the world state root at _blockNumber
     */
    event L2WorldStateProven(
        uint256 indexed _destinationChainID, uint256 indexed _blockNumber, bytes32 _L2WorldStateRoot
    );

    /**
     * @notice emitted on a proving state if the blockNumber is less than or equal to the current blockNumber + SETTLEMENT_BLOCKS_DELAY
     * @param _inputBlockNumber the block number we are trying to prove
     * @param _nextProvableBlockNumber the next block number that can be proven
     */
    error NeedLaterBlock(uint256 _inputBlockNumber, uint256 _nextProvableBlockNumber);

    /**
     * @notice emitted on a proving state if the blockNumber is less than or equal to the current blockNumber
     * @param _inputBlockNumber the block number we are trying to prove
     * @param _latestBlockNumber the latest block number that has been proven
     */
    error OutdatedBlock(uint256 _inputBlockNumber, uint256 _latestBlockNumber);

    /**
     * @notice emitted if the passed RLPEncodedBlockData Hash does not match the keccak256 hash of the RPLEncodedData
     * @param _expectedBlockHash the expected block hash for the RLP encoded data
     * @param _calculatedBlockHash the calculated block hash from the RLP encoded data
     */
    error InvalidRLPEncodedBlock(bytes32 _expectedBlockHash, bytes32 _calculatedBlockHash);

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
    error SettlementChainStateRootNotProved(bytes32 _blockProofStateRoot, bytes32 _l1WorldStateRoot);

    /**
     * @notice emitted when the settlement chain state root has not yet been proven
     * @param _blockProofStateRoot the state root of the block that we are trying to prove
     * @param _l2WorldStateRoot the state root of the last block that was proven on the settlement chain
     */
    error DestinationChainStateRootNotProved(bytes32 _blockProofStateRoot, bytes32 _l2WorldStateRoot);

    /**
     * @notice emitted when the settlement chain state root has not yet been proven
     * @param _blockTimeStamp the timestamp of the block that we are trying to prove
     * @param _finalityDelayTimeStamp the time stamp including finality delay that we need to wait for
     */
    error BlockBeforeFinalityPeriod(uint256 _blockTimeStamp, uint256 _finalityDelayTimeStamp);

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

    // Check that the intent has not expired and that the sender is permitted to solve intents
    modifier validRLPEncodeBlock(bytes calldata _rlpEncodedBlockData, bytes32 _expectedBlockHash) {
        bytes32 calculatedBlockHash = keccak256(_rlpEncodedBlockData);
        if (calculatedBlockHash == _expectedBlockHash) {
            _;
        } else {
            revert InvalidRLPEncodedBlock(_expectedBlockHash, calculatedBlockHash);
        }
    }

    constructor(uint256 _settlementBlocksDelay, ChainConfigurationConstructor[] memory _chainConfigurations) {
        SETTLEMENT_BLOCKS_DELAY = _settlementBlocksDelay;
        for (uint256 i = 0; i < _chainConfigurations.length; ++i) {
            _setChainConfiguration(_chainConfigurations[i].chainId, _chainConfigurations[i].chainConfiguration);
        }
    }

    function version() external pure returns (string memory) {
        return Semver.version();
    }

    function getProofType() external pure override returns (ProofType) {
        return PROOF_TYPE;
    }

    function _setChainConfiguration(uint256 chainId, ChainConfiguration memory chainConfiguration) internal {
        chainConfigurations[chainId] = chainConfiguration;
        if (block.chainid == chainId) {
            l1BlockhashOracle = IL1Block(chainConfiguration.blockhashOracle);
        }
    }

    /**
     * @notice validates a storage proof against using SecureMerkleTrie.verifyInclusionProof
     * @param _key key
     * @param _val value
     * @param _proof proof
     * @param _root root
     */
    function proveStorage(bytes memory _key, bytes memory _val, bytes[] memory _proof, bytes32 _root) public pure {
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
    function proveStorageBytes32(bytes memory _key, bytes32 _val, bytes[] memory _proof, bytes32 _root) public pure {
        // `RLPWriter.writeUint` properly encodes values by removing any leading zeros.
        bytes memory rlpEncodedValue = RLPWriter.writeUint(uint256(_val));
        if (!SecureMerkleTrie.verifyInclusionProof(_key, rlpEncodedValue, _proof, _root)) {
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
    function proveAccount(bytes memory _address, bytes memory _data, bytes[] memory _proof, bytes32 _root)
        public
        pure
    {
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
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(outputRootVersion, worldStateRoot, messagePasserStateRoot, latestBlockHash));
    }

    /**
     * @notice helper function for getting all rlp data encoded
     * @param dataList list of data elements to be encoded
     */
    function rlpEncodeDataLibList(bytes[] memory dataList) external pure returns (bytes memory) {
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
    function pack(uint32 _gameType, uint64 _timestamp, address _gameProxy) public pure returns (bytes32 gameId_) {
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
    function unpack(bytes32 _gameId) public pure returns (uint32 gameType_, uint64 timestamp_, address gameProxy_) {
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
    function _bytesToUint(bytes memory b) internal pure returns (uint256) {
        uint256 number;
        for (uint256 i = 0; i < b.length; i++) {
            number = number + uint256(uint8(b[i])) * (2 ** (8 * (b.length - (i + 1))));
        }
        return number;
    }

    /**
     * @notice assembles the game status storage slot (this is provided as a helper function for external calls)
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
    ) public pure returns (bytes32 gameStatusStorageSlotRLP) {
      // Packed data is 64 + 64 + 8 + 8 + 8 = 152 bits / 19 bytes.
      // Need to convert to `uint152` to preserve right alignment.
        return bytes32(
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

    /**
     * @notice validates input L1 block state against the L1 oracle contract.
     * @param rlpEncodedBlockData properly encoded L1 block data
     * @dev inputting the correct block's data encoded as expected will result in its hash matching
     * the blockhash found on the L1 oracle contract. This means that the world state root found
     * in that block corresponds to the block on the oracle contract, and that it represents a valid
     * state.
     */
    function proveSettlementLayerState(bytes calldata rlpEncodedBlockData)
        public
        validRLPEncodeBlock(rlpEncodedBlockData, l1BlockhashOracle.hash())
    {
        uint256 settlementChainId = chainConfigurations[block.chainid].settlementChainId;
        // not necessary because we already confirm that the data is correct by ensuring that it hashes to the block hash
        // require(l1WorldStateRoot.length <= 32); // ensure lossless casting to bytes32

        BlockProof memory blockProof = BlockProof({
            blockNumber: _bytesToUint(RLPReader.readBytes(RLPReader.readList(rlpEncodedBlockData)[8])),
            blockHash: keccak256(rlpEncodedBlockData),
            stateRoot: bytes32(RLPReader.readBytes(RLPReader.readList(rlpEncodedBlockData)[3]))
        });
        BlockProof memory existingBlockProof = provenStates[settlementChainId];
        if (existingBlockProof.blockNumber + SETTLEMENT_BLOCKS_DELAY < blockProof.blockNumber) {
            provenStates[settlementChainId] = blockProof;
            emit L1WorldStateProven(blockProof.blockNumber, blockProof.stateRoot);
        } else {
            revert NeedLaterBlock(blockProof.blockNumber, existingBlockProof.blockNumber + SETTLEMENT_BLOCKS_DELAY);
        }
    }
    /**
     * @notice Validates World state by ensuring that the passed in world state root corresponds to value in the L2 output oracle on the Settlement Layer
     * @param chainId the chain id of the chain we are proving
     * @param rlpEncodedBlockData properly encoded L1 block data
     * @param l2WorldStateRoot the state root of the last block in the batch which contains the block in which the fulfill tx happened
     * @param l2MessagePasserStateRoot // storage root / storage hash from eth_getProof(l2tol1messagePasser, [], block where intent was fulfilled)
     * @param l2OutputIndex the batch number
     * @param l1StorageProof storage proof from settlment chain for eth_getProof(L2OutputOracle, [], L1 block number)
     * @param rlpEncodedOutputOracleData rlp encoding of (balance, nonce, storageHash, codeHash) of eth_getProof(L2OutputOracle, [], L1 block number)
     * @param l1AccountProof accountProof from settlement chain for eth_getProof(L2OutputOracle, [], )
     * @param l1WorldStateRoot the l1 world state root that was proven in proveSettlementLayerState
     */

    function proveWorldStateBedrock(
        uint256 chainId, //the destination chain id of the intent we are proving
        bytes calldata rlpEncodedBlockData,
        bytes32 l2WorldStateRoot,
        bytes32 l2MessagePasserStateRoot,
        uint256 l2OutputIndex,
        bytes[] calldata l1StorageProof,
        bytes calldata rlpEncodedOutputOracleData,
        bytes[] calldata l1AccountProof,
        bytes32 l1WorldStateRoot
    ) public virtual {
        // could set a more strict requirement here to make the L1 block number greater than something corresponding to the intent creation
        // can also use timestamp instead of block when this is proven for better crosschain knowledge
        // failing the need for all that, change the mapping to map to bool
        ChainConfiguration memory chainConfiguration = chainConfigurations[chainId];
        BlockProof memory existingSettlementBlockProof = provenStates[chainConfiguration.settlementChainId];
        if (existingSettlementBlockProof.stateRoot != l1WorldStateRoot) {
            revert SettlementChainStateRootNotProved(existingSettlementBlockProof.stateRoot, l1WorldStateRoot);
        }

        // check that the End Batch Block timestamp is greater than the current timestamp + finality delay
        uint256 endBatchBlockTimeStamp = _bytesToUint(RLPReader.readBytes(RLPReader.readList(rlpEncodedBlockData)[11]));

        if (block.timestamp <= endBatchBlockTimeStamp + chainConfiguration.finalityDelaySeconds) {
            revert BlockBeforeFinalityPeriod(
                block.timestamp, endBatchBlockTimeStamp + chainConfiguration.finalityDelaySeconds
            );
        }

        bytes32 blockHash = keccak256(rlpEncodedBlockData);
        bytes32 outputRoot =
            generateOutputRoot(L2_OUTPUT_ROOT_VERSION_NUMBER, l2WorldStateRoot, l2MessagePasserStateRoot, blockHash);

        bytes32 outputRootStorageSlot =
            bytes32((uint256(keccak256(abi.encode(L2_OUTPUT_SLOT_NUMBER))) + l2OutputIndex * 2));

        bytes memory outputOracleStateRoot = RLPReader.readBytes(RLPReader.readList(rlpEncodedOutputOracleData)[2]);

        if (outputOracleStateRoot.length > 32) {
            revert IncorrectOutputOracleStateRoot(outputOracleStateRoot);
        }

        proveStorageBytes32(
            abi.encodePacked(outputRootStorageSlot), outputRoot, l1StorageProof, bytes32(outputOracleStateRoot)
        );

        proveAccount(
            abi.encodePacked(chainConfiguration.settlementContract),
            rlpEncodedOutputOracleData,
            l1AccountProof,
            l1WorldStateRoot
        );

        BlockProof memory existingBlockProof = provenStates[chainId];
        BlockProof memory blockProof = BlockProof({
            blockNumber: _bytesToUint(RLPReader.readBytes(RLPReader.readList(rlpEncodedBlockData)[8])),
            blockHash: blockHash,
            stateRoot: l2WorldStateRoot
        });
        if (existingBlockProof.blockNumber < blockProof.blockNumber) {
            provenStates[chainId] = blockProof;
            emit L2WorldStateProven(chainId, blockProof.blockNumber, blockProof.stateRoot);
        } else {
            if (existingBlockProof.blockNumber > blockProof.blockNumber) {
                revert OutdatedBlock(blockProof.blockNumber, existingBlockProof.blockNumber);
            }
        }
    }

    function _faultDisputeGameFromFactory(
        address disputeGameFactoryAddress,
        bytes32 l2WorldStateRoot,
        DisputeGameFactoryProofData calldata disputeGameFactoryProofData,
        bytes32 l1WorldStateRoot
    ) internal pure returns (address faultDisputeGameProxyAddress, bytes32 rootClaim) {
        bytes32 _rootClaim = generateOutputRoot(
            L2_OUTPUT_ROOT_VERSION_NUMBER,
            l2WorldStateRoot,
            disputeGameFactoryProofData.messagePasserStateRoot,
            disputeGameFactoryProofData.latestBlockHash
        );

        bytes32 disputeGameFactoryStorageSlot = bytes32(
            abi.encode(
                (
                    uint256(keccak256(abi.encode(L2_DISPUTE_GAME_FACTORY_LIST_SLOT_NUMBER)))
                        + disputeGameFactoryProofData.gameIndex
                )
            )
        );

        bytes memory disputeGameFactoryStateRoot =
            RLPReader.readBytes(RLPReader.readList(disputeGameFactoryProofData.rlpEncodedDisputeGameFactoryData)[2]);

        if (disputeGameFactoryStateRoot.length > 32) {
            revert IncorrectDisputeGameFactoryStateRoot(disputeGameFactoryStateRoot);
        }

        proveStorageBytes32(
            abi.encodePacked(disputeGameFactoryStorageSlot),
            disputeGameFactoryProofData.gameId,
            disputeGameFactoryProofData.disputeFaultGameStorageProof,
            bytes32(disputeGameFactoryStateRoot)
        );

        proveAccount(
            abi.encodePacked(disputeGameFactoryAddress),
            disputeGameFactoryProofData.rlpEncodedDisputeGameFactoryData,
            disputeGameFactoryProofData.disputeGameFactoryAccountProof,
            l1WorldStateRoot
        );

        (,, address _faultDisputeGameProxyAddress) = unpack(disputeGameFactoryProofData.gameId);

        return (_faultDisputeGameProxyAddress, _rootClaim);
    }

    function _faultDisputeGameIsResolved(
        bytes32 rootClaim,
        address faultDisputeGameProxyAddress,
        FaultDisputeGameProofData memory faultDisputeGameProofData,
        bytes32 l1WorldStateRoot
    ) internal pure {
        if (faultDisputeGameProofData.faultDisputeGameStatusSlotData.gameStatus != 2) {
            revert FaultDisputeGameUnresolved(faultDisputeGameProofData.faultDisputeGameStatusSlotData.gameStatus);
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
            faultDisputeGameProofData.faultDisputeGameStatusSlotData.l2BlockNumberChallenged
        );

        // faultDisputeGameProofData.faultDisputeGameStatusSlotData.filler
        // storage proof for FaultDisputeGame status (showing defender won)
        proveStorageBytes32(
            abi.encodePacked(uint256(L2_FAULT_DISPUTE_GAME_STATUS_SLOT)),
            faultDisputeGameStatusStorage,
            faultDisputeGameProofData.faultDisputeGameStatusStorageProof,
            bytes32(
                RLPReader.readBytes(RLPReader.readList(faultDisputeGameProofData.rlpEncodedFaultDisputeGameData)[2])
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

    /**
     * @notice Validates world state for Cannon by validating the following Storage proofs for the faultDisputeGame.
     * @notice 1) the rootClaim is correct by checking the gameId is in storage in the gamesList (will need to know the index number)
     * @notice 2) calculate the FaultDisputeGameAddress from the gameId
     * @notice 2) the l2BlockNumber is correct
     * @notice 3) the status is complete (2)
     * @notice this gives a total of 3 StorageProofs and 1 AccountProof which must be validated.
     * @param chainId the chain id of the chain we are proving
     * @param rlpEncodedBlockData properly encoded L1 block data
     * @param l2WorldStateRoot the state root of the last block in the batch which contains the block in which the fulfill tx happened
     * @param disputeGameFactoryProofData the proof data for the DisputeGameFactory
     * @param faultDisputeGameProofData the proof data for the FaultDisputeGame
     * @param l1WorldStateRoot the l1 world state root that was proven for the settlement chain
     */
    function proveWorldStateCannon(
        uint256 chainId, //the destination chain id of the intent we are proving
        bytes calldata rlpEncodedBlockData,
        bytes32 l2WorldStateRoot,
        DisputeGameFactoryProofData calldata disputeGameFactoryProofData,
        FaultDisputeGameProofData memory faultDisputeGameProofData,
        bytes32 l1WorldStateRoot
    ) public validRLPEncodeBlock(rlpEncodedBlockData, disputeGameFactoryProofData.latestBlockHash) {
        ChainConfiguration memory chainConfiguration = chainConfigurations[chainId];
        BlockProof memory existingSettlementBlockProof = provenStates[chainConfiguration.settlementChainId];
        if (existingSettlementBlockProof.stateRoot != l1WorldStateRoot) {
            revert SettlementChainStateRootNotProved(existingSettlementBlockProof.stateRoot, l1WorldStateRoot);
        }
        // prove that the FaultDisputeGame was created by the Dispute Game Factory

        bytes32 rootClaim;
        address faultDisputeGameProxyAddress;

        (faultDisputeGameProxyAddress, rootClaim) = _faultDisputeGameFromFactory(
            chainConfiguration.settlementContract, l2WorldStateRoot, disputeGameFactoryProofData, l1WorldStateRoot
        );

        _faultDisputeGameIsResolved(
            rootClaim, faultDisputeGameProxyAddress, faultDisputeGameProofData, l1WorldStateRoot
        );

        BlockProof memory existingBlockProof = provenStates[chainId];
        BlockProof memory blockProof = BlockProof({
            blockNumber: _bytesToUint(RLPReader.readBytes(RLPReader.readList(rlpEncodedBlockData)[8])),
            blockHash: keccak256(rlpEncodedBlockData),
            stateRoot: l2WorldStateRoot
        });
        if (existingBlockProof.blockNumber < blockProof.blockNumber) {
            provenStates[chainId] = blockProof;
            emit L2WorldStateProven(chainId, blockProof.blockNumber, blockProof.stateRoot);
        } else {
            if (existingBlockProof.blockNumber > blockProof.blockNumber) {
                revert OutdatedBlock(blockProof.blockNumber, existingBlockProof.blockNumber);
            }
        }
    }

    /**
     * @notice Validates an intent has been proven by checking the storage proof on the destination chain
     * to ensure that the inentHash maps to the claimant address in the inbox contract
     * @param chainId the destination chain id of the intent we are proving
     * @param claimant the address that can claim the reward
     * @param inboxContract the address of the inbox contract on the destination chain
     * @param intermediateHash the hash which, when hashed with the correct inbox contract, will result in the correct intentHash
     * @param l2StorageProof A storage proof for the intentHash mapping to the claimant address
     * @param rlpEncodedInboxData RLP encoded data for the inbox contract including nonce, balance, storageHash, codeHash
     * @param l2AccountProof An account proof for the destination chain  inbox contract
     * @param l2WorldStateRoot The world state root of the destination chain
     */
    function proveIntent(
        uint256 chainId, //the destination chain id of the intent we are proving
        address claimant,
        address inboxContract,
        bytes32 intermediateHash,
        bytes[] calldata l2StorageProof,
        bytes calldata rlpEncodedInboxData,
        bytes[] calldata l2AccountProof,
        bytes32 l2WorldStateRoot
    ) public {
        // ChainConfiguration memory chainConfiguration = chainConfigurations[chainId];
        BlockProof memory existingBlockProof = provenStates[chainId];
        if (existingBlockProof.stateRoot != l2WorldStateRoot) {
            revert DestinationChainStateRootNotProved(existingBlockProof.stateRoot, l2WorldStateRoot);
        }

        bytes32 intentHash = keccak256(abi.encode(inboxContract, intermediateHash));

        bytes32 messageMappingSlot = keccak256(
            abi.encode(
                intentHash,
                1 // storage position of the intents mapping is the first slot
            )
        );

        bytes memory inboxStateRoot = RLPReader.readBytes(RLPReader.readList(rlpEncodedInboxData)[2]);

        if (inboxStateRoot.length > 32) {
            revert IncorrectInboxStateRoot(inboxStateRoot);
        }
        // proves that the claimaint address corresponds to the intentHash on the contract
        proveStorageBytes32(
            abi.encodePacked(messageMappingSlot),
            bytes32(uint256(uint160(claimant))),
            l2StorageProof,
            bytes32(inboxStateRoot)
        );

        // proves that the inbox data corresponds to the l2worldstate
        proveAccount(abi.encodePacked(inboxContract), rlpEncodedInboxData, l2AccountProof, l2WorldStateRoot);

        provenIntents[intentHash] = claimant;
        emit IntentProven(intentHash, claimant);
    }
}
