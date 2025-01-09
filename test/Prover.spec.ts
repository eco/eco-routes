import { ethers } from 'hardhat'
import { expect } from 'chai'
import { deploy } from './utils'
import { cloneDeep } from 'lodash'
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import { MockL1Block__factory, Prover } from '../typechain-types'
import {
  AbiCoder,
  encodeRlp,
  getAddress,
  getBytes,
  keccak256,
  toBeHex,
  solidityPackedKeccak256,
  stripZerosLeft,
} from 'ethers'
import {
  networkIds,
  networks,
  provingMechanisms,
  settlementTypes,
  deploymentChainConfigs,
} from '../config/local/config'
import {
  bedrock,
  cannon,
  l1l3SettlementLayerState,
} from '../config/local/testData'

import { utils } from '../scripts/common/utils'

// Unit Tests
// describe('Prover Unit Tests', () => {
//   let deployerSigner: SignerWithAddress
//   let intentCreatorSigner: SignerWithAddress
//   let solverSigner: SignerWithAddress
//   let claimantSigner: SignerWithAddress
//   let proverSigner: SignerWithAddress
//   let recipientSigner: SignerWithAddress
//   let prover: Prover
//   let blockhashOracle

//   before(async () => {
//     ;[
//       deployerSigner,
//       intentCreatorSigner,
//       solverSigner,
//       claimantSigner,
//       proverSigner,
//       recipientSigner,
//     ] = await ethers.getSigners()
//   })

//   beforeEach(async () => {
//     const proverContract = await ethers.getContractFactory('Prover')
//     prover = await proverContract.deploy(deploymentChainConfigs.unitTests)
//   })

//   describe('on prover implements interface', () => {
//     it('should return the correct proof type', async () => {
//       expect(await prover.getProofType()).to.equal(0)
//     })
//   })

//   it('test ethers functions', async () => {
//     expect('0x84457ca9D0163FbC4bbfe4Dfbb20ba46e48DF254').to.equal(
//       getAddress('0x84457ca9D0163FbC4bbfe4Dfbb20ba46e48DF254'),
//     )
//     expect('0x56315b90c40730925ec5485cf004d835058518A0').to.equal(
//       getAddress('0x56315b90c40730925ec5485cf004d835058518A0'),
//     )
//   })
//   it('test generateOutputRoot', async () => {
//     const cannonRootClaimFromProver = await prover.generateOutputRoot(
//       0,
//       cannon.destinationChain.endBatchBlockStateRoot,
//       cannon.destinationChain.messagePasserStateRoot,
//       cannon.destinationChain.endBatchBlockHash,
//     )
//     expect(cannonRootClaimFromProver).to.equal(
//       cannon.destinationChain.disputeGameFactory.faultDisputeGame.rootClaim,
//     )
//   })
//   it('test rlpEncodeDataLibList', async () => {
//     const rlpEncodeDataLibList = await prover.rlpEncodeDataLibList(
//       cannon.destinationChain.disputeGameFactory.contractData,
//     )
//     expect(rlpEncodeDataLibList).to.equal(
//       '0xf84682017780a0f8f08690d07bf01927230d32b6e4b72f5495e885604a5098f17c3a3b7dd7e72ca0fa8c9db6c6cab7108dea276f4cd09d575674eb0852c0fa3187e59e98ef977998',
//     )
//   })
//   it('test unpack', async () => {
//     const gameUnpacked = await prover.unpack(
//       cannon.destinationChain.disputeGameFactory.faultDisputeGame.gameId,
//     )
//     expect(gameUnpacked.gameType_).to.equal(0)
//     expect(gameUnpacked.timestamp_).to.equal(
//       cannon.destinationChain.faultDisputeGame.status.storage.createdAt,
//     )
//     expect(gameUnpacked.gameProxy_).to.equal(
//       cannon.destinationChain.faultDisputeGame.address,
//     )
//   })
//   it('test assembleGameStatusStorage', async () => {
//     await prover.assembleGameStatusStorage(
//       cannon.destinationChain.faultDisputeGame.status.storage.createdAt,
//       cannon.destinationChain.faultDisputeGame.status.storage.resolvedAt,
//       cannon.destinationChain.faultDisputeGame.status.storage.gameStatus,
//       cannon.destinationChain.faultDisputeGame.status.storage.initialized,
//       cannon.destinationChain.faultDisputeGame.status.storage
//         .l2BlockNumberChallenged,
//       getBytes(cannon.destinationChain.faultDisputeGame.status.storage.filler),
//     )
//   })
//   it('test proveStorage', async () => {
//     // Prove storage showing the FaultDispute Game has a rootClaim which includes the L2Block
//     await prover.proveStorage(
//       cannon.destinationChain.faultDisputeGame.rootClaim.storageSlot,
//       encodeRlp(
//         toBeHex(
//           stripZerosLeft(
//             cannon.destinationChain.faultDisputeGame.rootClaim.storageData,
//           ),
//         ),
//       ),
//       // encodeRlp(cannon.faultDisputeGameRootClaimStorage),
//       cannon.destinationChain.faultDisputeGame.rootClaim.storageProof,
//       cannon.destinationChain.faultDisputeGame.stateRoot,
//     )
//   })
//   it('test proveAccount', async () => {
//     await prover.proveAccount(
//       cannon.destinationChain.faultDisputeGame.address,
//       await prover.rlpEncodeDataLibList(
//         cannon.destinationChain.faultDisputeGame.contractData,
//       ),
//       cannon.destinationChain.faultDisputeGame.accountProof,
//       cannon.settlementChain.worldStateRoot,
//     )
//   })
// })

// Prove Self State test checks that proving self state works
describe('Prove Self State Tests', () => {
  let deployerSigner: SignerWithAddress
  let intentCreatorSigner: SignerWithAddress
  let solverSigner: SignerWithAddress
  let claimantSigner: SignerWithAddress
  let proverSigner: SignerWithAddress
  let recipientSigner: SignerWithAddress
  let prover: Prover
  let blockhashOracle

  before(async () => {
    ;[
      deployerSigner,
      intentCreatorSigner,
      solverSigner,
      claimantSigner,
      proverSigner,
      recipientSigner,
    ] = await ethers.getSigners()
  })

  beforeEach(async () => {
    console.log('Prove Self State Tests')
    // console.log('deploymentChainConfig: ', deploymentChainConfig)
    blockhashOracle = await deploy(deployerSigner, MockL1Block__factory)
    // only the number and hash matters here
    await blockhashOracle.setL1BlockValues(
      bedrock.settlementChain.blockNumber,
      0,
      0,
      bedrock.settlementChain.blockHash,
      0,
      '0x' + '00'.repeat(32),
      0,
      0,
    )
    const chainConfig = cloneDeep(deploymentChainConfigs.selfStateTests)
    const deploymentChains = []
    for (const chain of chainConfig) {
      chain.chainConfiguration.blockhashOracle =
        await blockhashOracle.getAddress()
      deploymentChains.push(chain)
    }
    const proverContract = await ethers.getContractFactory('Prover')
    prover = await proverContract.deploy(deploymentChains)
  })
  it('test proveSelfState fails with invalid block', async () => {
    // test it is valid for a block in the last 256 blocks
    // get the block from hardhat
    // prove the block
    const blockNumber = await ethers.provider.getBlockNumber()
    const blockData = await ethers.provider.getBlock(blockNumber)
    await expect(
      prover.proveSelfState(bedrock.settlementChain.rlpEncodedBlockData),
    ).to.be.revertedWith('blockhash is not in last 256 blocks for this chain')
  })
  it('test proveSelfState fails with block older than 256 blocks', async () => {
    // TODO add in logic for getting the block data and calculating the hash
    const blockNumber = await ethers.provider.getBlockNumber()
    const blockData = await ethers.provider.getBlock(blockNumber)
    const rlpEncodedBlockData = await utils.getRLPEncodedBlockHardhat(blockData)
    await expect(
      prover.proveSelfState(bedrock.settlementChain.rlpEncodedBlockData),
    ).to.be.revertedWith('blockhash is not in last 256 blocks for this chain')
  })

  it('test proveSelfState works for a valid block', async () => {
    // TODO: need to work out hashing logic for block data for hardhat
    // const blockNumber = await ethers.provider.getBlockNumber()
    // const blockData = await ethers.provider.getBlock(blockNumber, true)
    // // console.log('blockData: ', blockData)
    // const rlpEncodedBlockData = await utils.getRLPEncodedBlockHardhat(blockData)
    // console.log('rlpEncodedBlockData: ', rlpEncodedBlockData)
    // console.log('blockData.hash         : ', blockData.hash)
    // console.log('rlpEncodedBlockDataHash: ', keccak256(rlpEncodedBlockData))
    // await expect(
    //   prover.proveSelfState(bedrock.settlementChain.rlpEncodedBlockData),
    // )
    //   .to.emit(prover, 'SelfStateProven')
    //   .withArgs(
    //     bedrock.settlementChain.blockNumber,
    //     bedrock.settlementChain.worldStateRoot,
    //   )
  })

  it('test proveSelfState fails if using an older block than current state', async () => {
    // const blockNumber = await ethers.provider.getBlockNumber()
    // const blockData = await ethers.provider.getBlock(blockNumber)
    // await expect(
    //   prover.proveSelfState(bedrock.settlementChain.rlpEncodedBlockData),
    // )
    //   .to.emit(prover, 'SelfStateProven')
    //   .withArgs(
    //     bedrock.settlementChain.blockNumber,
    //     bedrock.settlementChain.worldStateRoot,
    //   )
  })
})

// The Prover End to End Tests Proves a sample Intent from OptimismSepolia to EcoTestnet
// This involves
// proving SettlementLayerState (Sepolia)
// proving WorldStateCannon (Base)
// proving WorldStateBedrock (EcoTestnet)
// proving Intent (Base -> EcoTestnet)

describe('Prover End to End Tests', () => {
  let deployerSigner: SignerWithAddress
  let intentCreatorSigner: SignerWithAddress
  let solverSigner: SignerWithAddress
  let claimantSigner: SignerWithAddress
  let proverSigner: SignerWithAddress
  let recipientSigner: SignerWithAddress
  let prover: Prover
  let blockhashOracle

  before(async () => {
    ;[
      deployerSigner,
      intentCreatorSigner,
      solverSigner,
      claimantSigner,
      proverSigner,
      recipientSigner,
    ] = await ethers.getSigners()
  })

  beforeEach(async () => {
    blockhashOracle = await deploy(deployerSigner, MockL1Block__factory)
    // only the number and hash matters here
    await blockhashOracle.setL1BlockValues(
      bedrock.settlementChain.blockNumber,
      0,
      0,
      bedrock.settlementChain.blockHash,
      0,
      '0x' + '00'.repeat(32),
      0,
      0,
    )
    const chainConfig = cloneDeep(deploymentChainConfigs.endToEndTests)
    const deploymentChains = []
    for (const chain of chainConfig) {
      chain.chainConfiguration.blockhashOracle =
        await blockhashOracle.getAddress()
      deploymentChains.push(chain)
    }
    const proverContract = await ethers.getContractFactory('Prover')
    prover = await proverContract.deploy(deploymentChains)
  })

  it('test proveSettlementLayerState', async () => {
    await expect(
      prover.proveSettlementLayerState(
        bedrock.settlementChain.rlpEncodedBlockData,
      ),
    )
      .to.emit(prover, 'L1WorldStateProven')
      .withArgs(
        bedrock.settlementChain.blockNumber,
        bedrock.settlementChain.worldStateRoot,
      )

    const provenSettlementLayerState = await prover.provenStates(
      networks.sepolia.chainId,
      settlementTypes.Confirmed,
    )
    expect(provenSettlementLayerState.blockNumber).to.equal(
      bedrock.settlementChain.blockNumber,
    )
    expect(provenSettlementLayerState.blockHash).to.equal(
      bedrock.settlementChain.blockHash,
    )
    expect(provenSettlementLayerState.stateRoot).to.equal(
      bedrock.settlementChain.worldStateRoot,
    )

    // test proveWorldStateCannon'
    const RLPEncodedDisputeGameFactoryData = await prover.rlpEncodeDataLibList(
      bedrock.baseSepolia.disputeGameFactory.contractData,
    )
    // Prove the L2 World State for Cannon
    const disputeGameFactoryProofData = {
      messagePasserStateRoot: bedrock.baseSepolia.messagePasserStateRoot,
      latestBlockHash: bedrock.baseSepolia.endBatchBlockHash,
      gameIndex:
        bedrock.baseSepolia.disputeGameFactory.faultDisputeGame.gameIndex,
      gameId: bedrock.baseSepolia.disputeGameFactory.faultDisputeGame.gameId,
      disputeFaultGameStorageProof:
        bedrock.baseSepolia.disputeGameFactory.storageProof,
      rlpEncodedDisputeGameFactoryData: RLPEncodedDisputeGameFactoryData,
      disputeGameFactoryAccountProof:
        bedrock.baseSepolia.disputeGameFactory.accountProof,
    }

    const RLPEncodedFaultDisputeGameData = await prover.rlpEncodeDataLibList(
      bedrock.baseSepolia.faultDisputeGame.contractData,
    )
    const faultDisputeGameProofData = {
      faultDisputeGameStateRoot: bedrock.baseSepolia.faultDisputeGame.stateRoot,
      faultDisputeGameRootClaimStorageProof:
        bedrock.baseSepolia.faultDisputeGame.rootClaim.storageProof,
      faultDisputeGameStatusSlotData: {
        createdAt:
          bedrock.baseSepolia.faultDisputeGame.status.storage.createdAt,
        resolvedAt:
          bedrock.baseSepolia.faultDisputeGame.status.storage.resolvedAt,
        gameStatus:
          bedrock.baseSepolia.faultDisputeGame.status.storage.gameStatus,
        initialized:
          bedrock.baseSepolia.faultDisputeGame.status.storage.initialized,
        l2BlockNumberChallenged:
          bedrock.baseSepolia.faultDisputeGame.status.storage
            .l2BlockNumberChallenged,
      },
      faultDisputeGameStatusStorageProof:
        bedrock.baseSepolia.faultDisputeGame.status.storageProof,
      rlpEncodedFaultDisputeGameData: RLPEncodedFaultDisputeGameData,
      faultDisputeGameAccountProof:
        bedrock.baseSepolia.faultDisputeGame.accountProof,
    }
    await expect(
      prover.proveWorldStateCannon(
        networkIds.baseSepolia,
        bedrock.baseSepolia.rlpEncodedendBatchBlockData,
        // RLPEncodedBaseSepoliaEndBatchBlock,
        bedrock.baseSepolia.endBatchBlockStateRoot,
        disputeGameFactoryProofData,
        faultDisputeGameProofData,
        bedrock.settlementChain.worldStateRoot,
      ),
    )
      .to.emit(prover, 'L2WorldStateProven')
      .withArgs(
        networkIds.baseSepolia,
        bedrock.baseSepolia.endBatchBlock,
        bedrock.baseSepolia.worldStateRoot,
      )
    const provenBaseSepoliaLayerState = await prover.provenStates(
      networks.baseSepolia.chainId,
      settlementTypes.Finalized,
    )
    expect(provenBaseSepoliaLayerState.blockNumber).to.equal(
      bedrock.baseSepolia.endBatchBlock,
    )
    expect(provenBaseSepoliaLayerState.blockHash).to.equal(
      bedrock.baseSepolia.endBatchBlockHash,
    )
    expect(provenBaseSepoliaLayerState.stateRoot).to.equal(
      bedrock.baseSepolia.worldStateRoot,
    )

    // test proveWorldStateBedrock

    await expect(
      prover.proveWorldStateBedrock(
        bedrock.intent.destinationChainId,
        bedrock.destinationChain.rlpEncodedBlockData, // TODO: Check if this is the correct data
        bedrock.destinationChain.worldStateRoot,
        bedrock.destinationChain.messageParserStateRoot,
        bedrock.destinationChain.batchIndex,
        bedrock.baseSepolia.storageProof,
        await prover.rlpEncodeDataLibList(
          bedrock.destinationChain.contractData,
        ),
        bedrock.baseSepolia.accountProof,
        bedrock.baseSepolia.worldStateRoot,
      ),
    )
      .to.emit(prover, 'L2WorldStateProven')
      .withArgs(
        bedrock.intent.destinationChainId,
        bedrock.destinationChain.endBatchBlock,
        bedrock.destinationChain.worldStateRoot,
      )

    const provenEcoTestnetLayerState = await prover.provenStates(
      networkIds.ecoTestnet,
      settlementTypes.Finalized,
    )
    expect(provenEcoTestnetLayerState.blockNumber).to.equal(
      bedrock.destinationChain.endBatchBlock,
    )
    expect(provenEcoTestnetLayerState.blockHash).to.equal(
      bedrock.destinationChain.endBatchBlockHash,
    )
    expect(provenEcoTestnetLayerState.stateRoot).to.equal(
      bedrock.destinationChain.worldStateRoot,
    )

    // test proveIntent
    const abiCoder = AbiCoder.defaultAbiCoder()
    const calcintentHash = keccak256(
      abiCoder.encode(
        ['address', 'bytes32'],
        [networks.ecoTestnet.inbox.address, bedrock.intent.intermediateHash],
      ),
    )
    // const intentStorageSlot = solidityPackedKeccak256(
    //   ['bytes'],
    //   [abiCoder.encode(['bytes32', 'uint256'], [calcintentHash, 1])],
    // )
    //TODO: Need to generate new intent Data for Inbox contract changes
    // await prover.proveIntent(
    //   bedrock.intent.destinationChainId,
    //   settlementTypes.Finalized,
    //   getAddress(actors.claimant),
    //   networks.ecoTestnet.inbox.address,
    //   bedrock.intent.intermediateHash,
    //   bedrock.intent.storageProof,
    //   await prover.rlpEncodeDataLibList(bedrock.intent.inboxContractData),
    //   bedrock.intent.accountProof,
    //   bedrock.intent.endBatchBlockStateRoot,
    // )
  })
})

// proveL1L3SettlementLayerState
// This uses Hardhat as the source chain representing ecoTestnet
// BaseSepolia is the L2 settlement chain
// Sepolia is the L1 settlement chain
// OptimismSepolia is the Destination Chain
describe('Prover L3 Settlement Layer Tests', () => {
  let deployerSigner: SignerWithAddress
  let intentCreatorSigner: SignerWithAddress
  let solverSigner: SignerWithAddress
  let claimantSigner: SignerWithAddress
  let proverSigner: SignerWithAddress
  let recipientSigner: SignerWithAddress
  let prover: Prover
  let blockhashOracle

  before(async () => {
    ;[
      deployerSigner,
      intentCreatorSigner,
      solverSigner,
      claimantSigner,
      proverSigner,
      recipientSigner,
    ] = await ethers.getSigners()
  })

  beforeEach(async () => {
    blockhashOracle = await deploy(deployerSigner, MockL1Block__factory)
    // only the number and hash matters here
    await blockhashOracle.setL1BlockValues(
      l1l3SettlementLayerState.l2BlockTag,
      0,
      0,
      l1l3SettlementLayerState.l2BlockHash,
      0,
      '0x' + '00'.repeat(32),
      0,
      0,
    )
    const chainConfig = cloneDeep(deploymentChainConfigs.l3SettlementTests)
    const deploymentChains = []
    for (const chain of chainConfig) {
      chain.chainConfiguration.blockhashOracle =
        await blockhashOracle.getAddress()
      // change the Settlement Types for Sepolia and BaseSepolia for SettlementL3
      // if (chain.chainConfigurationKey.chainId === networkIds.sepolia) {
      //   chain.chainConfigurationKey.provingMechanism =
      //     provingMechanisms.SettlementL3
      // }
      // if (chain.chainConfigurationKey.chainId === networkIds.baseSepolia) {
      //   chain.chainConfigurationKey.provingMechanism =
      //     provingMechanisms.Settlement
      // }
      deploymentChains.push(chain)
      // if (chain.chainConfigurationKey.chainId === networkIds.ecoTestnet) {
      //   const hardhatChain = cloneDeep(chain)
      //   hardhatChain.chainConfigurationKey.chainId = networkIds.hardhat
      //   deploymentChains.push(hardhatChain)
      // }
    }
    const proverContract = await ethers.getContractFactory('Prover')
    prover = await proverContract.deploy(deploymentChains)
  })

  // it('test l1l3 StorageProof', async () => {
  //   await prover.proveStorage(
  //     l1l3SettlementLayerState.storageProof.l2BlockHashSlot,
  //     l1l3SettlementLayerState.storageProof.rlpL1BlockHash,
  //     l1l3SettlementLayerState.storageProof.storageProof,
  //     l1l3SettlementLayerState.storageProof.storageHash,
  //   )
  // })
  // it('test l1l3 AccountProof', async () => {
  //   await prover.proveAccount(
  //     l1l3SettlementLayerState.accountProof.l1BlockAddress,
  //     l1l3SettlementLayerState.accountProof.RLPEncodedl2l1BlockContractData,
  //     l1l3SettlementLayerState.accountProof.accountProof,
  //     l1l3SettlementLayerState.accountProof.stateRoot,
  //   )
  // })
  it('test l1l3SettlementState', async () => {
    await prover.proveL1L3SettlementLayerState(
      l1l3SettlementLayerState.parameters.l1RlpEncodedBlockData,
      l1l3SettlementLayerState.parameters.l2RlpEncodedBlockData,
      l1l3SettlementLayerState.parameters.l2l1StorageProof,
      l1l3SettlementLayerState.parameters.rlpEncodedL2L1BlockData,
      l1l3SettlementLayerState.parameters.l2AccountProof,
      l1l3SettlementLayerState.parameters.l2WorldStateRoot,
    )
  })
})
