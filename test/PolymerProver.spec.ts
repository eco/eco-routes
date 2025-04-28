import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  PolymerProver,
  Inbox,
  TestERC20,
  TestCrossL2ProverV2,
  MockIntentSource,
} from '../typechain-types'
import { encodeTransfer } from '../utils/encode'
import { TokenAmount, Reward } from '../utils/intent'

export function hashIntent(routeHash: string, reward: Reward): string {
  // Use the full Reward type for encoding, matching the Solidity abi.encode(reward)
  const rewardHash = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      [
        'tuple(address creator, address prover, uint256 deadline, uint256 nativeValue, tuple(address token, uint256 amount)[] tokens)',
      ],
      [reward],
    ),
  )

  return ethers.keccak256(
    ethers.solidityPacked(['bytes32', 'bytes32'], [routeHash, rewardHash]),
  )
}

describe('PolymerProver Test', (): void => {
  let polymerProver: PolymerProver
  let inbox: Inbox
  let testCrossL2ProverV2: TestCrossL2ProverV2
  let mockIntentSource: MockIntentSource
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let claimant: SignerWithAddress
  let claimant2: SignerWithAddress
  let claimant3: SignerWithAddress
  let token: SignerWithAddress
  let chainIds: number[] = [10, 42161]
  let emptyTopics: string =
    '0x0000000000000000000000000000000000000000000000000000000000000000'
  let emptyData: string = '0x'

  async function deployPolymerProverFixture(): Promise<{
    polymerProver: PolymerProver
    inbox: Inbox
    testCrossL2ProverV2: TestCrossL2ProverV2
    owner: SignerWithAddress
    solver: SignerWithAddress
    claimant: SignerWithAddress
    claimant2: SignerWithAddress
    claimant3: SignerWithAddress
    token: SignerWithAddress
  }> {
    const [owner, solver, claimant, claimant2, claimant3, token] =
      await ethers.getSigners()

    const inbox = await (
      await ethers.getContractFactory('Inbox')
    ).deploy(await owner.getAddress(), true, 0, [])

    const testCrossL2ProverV2 = await (
      await ethers.getContractFactory('TestCrossL2ProverV2')
    ).deploy(chainIds[0], await inbox.getAddress(), emptyTopics, emptyData)

    polymerProver = await (
      await ethers.getContractFactory('PolymerProver')
    ).deploy(
      await testCrossL2ProverV2.getAddress(),
      await inbox.getAddress(),
      chainIds,
    )

    return {
      polymerProver,
      inbox,
      testCrossL2ProverV2,
      owner,
      solver,
      claimant,
      claimant2,
      claimant3,
      token,
    }
  }

  beforeEach(async (): Promise<void> => {
    ;({
      polymerProver,
      inbox,
      testCrossL2ProverV2,
      mockIntentSource,
      solver,
      claimant,
      claimant2,
      claimant3,
      token,
    } = await loadFixture(deployPolymerProverFixture))
  })

  describe('Single emit', (): void => {
    let topics: string[]
    let data: string
    let expectedHash: string
    let eventSignature: string
    let badEventSignature: string

    beforeEach(async (): Promise<void> => {
      eventSignature = ethers.id('ToBeProven(bytes32,uint256,address)')
      badEventSignature = ethers.id(
        'BadEventSignature(bytes32,uint256,address)',
      )
      expectedHash = '0x' + '11'.repeat(32)
      data = '0x'
      topics = [
        eventSignature,
        expectedHash,
        ethers.zeroPadValue(ethers.toBeHex(chainIds[0]), 32),
        ethers.zeroPadValue(claimant.address, 32),
      ]
    })

    it('should validate a single emit', async (): Promise<void> => {
      const topicsPacked = ethers.solidityPacked(
        ['bytes32', 'bytes32', 'bytes32', 'bytes32'],
        topics,
      )
      const inboxAddress = await inbox.getAddress()

      // set values for mock prover
      await testCrossL2ProverV2.setAll(
        chainIds[0],
        inboxAddress,
        topicsPacked,
        data,
      )

      // set values for mock proof index
      // start at 1 because we have already set the first index in constructor
      const proofIndex = 1
      const proof = ethers.zeroPadValue(ethers.toBeHex(proofIndex), 32)

      // get values from mock prover and ensure they are correct
      const [
        chainId_returned,
        emittingContract_returned,
        topics_returned,
        data_returned,
      ] = await testCrossL2ProverV2.validateEvent(proof)

      expect(chainId_returned).to.equal(chainIds[0])
      expect(emittingContract_returned).to.equal(inboxAddress)
      expect(topics_returned).to.equal(topicsPacked)
      expect(data_returned).to.equal(data)

      await expect(polymerProver.validate(proof))
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(expectedHash, claimant.address)
    })

    it('should emit IntentAlreadyProven if the proof is already proven', async (): Promise<void> => {
      const topicsPacked = ethers.solidityPacked(
        ['bytes32', 'bytes32', 'bytes32', 'bytes32'],
        topics,
      )
      const inboxAddress = await inbox.getAddress()

      // set values for mock prover
      await testCrossL2ProverV2.setAll(
        chainIds[0],
        inboxAddress,
        topicsPacked,
        data,
      )

      // set values for mock proof index
      // start at 1 because we have already set the first index in constructor
      const proofIndex = 1
      const proof = ethers.zeroPadValue(ethers.toBeHex(proofIndex), 32)

      // get values from mock prover and ensure they are correct
      const [
        chainId_returned,
        emittingContract_returned,
        topics_returned,
        data_returned,
      ] = await testCrossL2ProverV2.validateEvent(proof)

      expect(chainId_returned).to.equal(chainIds[0])
      expect(emittingContract_returned).to.equal(inboxAddress)
      expect(topics_returned).to.equal(topicsPacked)
      expect(data_returned).to.equal(data)

      await expect(polymerProver.validate(proof))
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(expectedHash, claimant.address)

      await expect(polymerProver.validate(proof))
        .to.emit(polymerProver, 'IntentAlreadyProven')
        .withArgs(expectedHash)
    })

    it('should revert if inbox contract is not the emitting contract', async (): Promise<void> => {
      const topicsPacked = ethers.solidityPacked(
        ['bytes32', 'bytes32', 'bytes32', 'bytes32'],
        topics,
      )

      // set values for mock prover
      await testCrossL2ProverV2.setAll(
        chainIds[0],
        claimant.address,
        topicsPacked,
        data,
      )

      // set values for mock proof index
      // start at 1 because we have already set the first index in constructor
      const proofIndex = 1
      const proof = ethers.zeroPadValue(ethers.toBeHex(proofIndex), 32)

      // get values from mock prover and ensure they are correct
      const [
        chainId_returned,
        emittingContract_returned,
        topics_returned,
        data_returned,
      ] = await testCrossL2ProverV2.validateEvent(proof)

      expect(chainId_returned).to.equal(chainIds[0])
      expect(emittingContract_returned).to.equal(claimant.address)
      expect(topics_returned).to.equal(topicsPacked)
      expect(data_returned).to.equal(data)

      await expect(polymerProver.validate(proof)).to.be.revertedWithCustomError(
        polymerProver,
        'InvalidEmittingContract',
      )
    })

    it('should revert if chainId is not supported', async (): Promise<void> => {
      const topicsPacked = ethers.solidityPacked(
        ['bytes32', 'bytes32', 'bytes32', 'bytes32'],
        topics,
      )
      const inboxAddress = await inbox.getAddress()

      const badChainId = 1234

      // set values for mock prover
      await testCrossL2ProverV2.setAll(
        badChainId,
        inboxAddress,
        topicsPacked,
        data,
      )

      // set values for mock proof index
      // start at 1 because we have already set the first index in constructor
      const proofIndex = 1
      const proof = ethers.zeroPadValue(ethers.toBeHex(proofIndex), 32)

      // get values from mock prover and ensure they are correct
      const [
        chainId_returned,
        emittingContract_returned,
        topics_returned,
        data_returned,
      ] = await testCrossL2ProverV2.validateEvent(proof)

      expect(chainId_returned).to.equal(badChainId)
      expect(emittingContract_returned).to.equal(inboxAddress)
      expect(topics_returned).to.equal(topicsPacked)
      expect(data_returned).to.equal(data)

      await expect(polymerProver.validate(proof)).to.be.revertedWithCustomError(
        polymerProver,
        'UnsupportedChainId',
      )
    })

    it('should revert if topics length is not 4', async (): Promise<void> => {
      topics = [
        eventSignature,
        expectedHash,
        ethers.zeroPadValue(ethers.toBeHex(chainIds[0]), 32),
      ]

      const topicsPacked = ethers.solidityPacked(
        ['bytes32', 'bytes32', 'bytes32'],
        topics,
      )
      const inboxAddress = await inbox.getAddress()

      // set values for mock prover
      await testCrossL2ProverV2.setAll(
        chainIds[0],
        inboxAddress,
        topicsPacked,
        data,
      )

      // set values for mock proof index
      // start at 1 because we have already set the first index in constructor
      const proofIndex = 1
      const proof = ethers.zeroPadValue(ethers.toBeHex(proofIndex), 32)

      // get values from mock prover and ensure they are correct
      const [
        chainId_returned,
        emittingContract_returned,
        topics_returned,
        data_returned,
      ] = await testCrossL2ProverV2.validateEvent(proof)

      expect(chainId_returned).to.equal(chainIds[0])
      expect(emittingContract_returned).to.equal(inboxAddress)
      expect(topics_returned).to.equal(topicsPacked)
      expect(data_returned).to.equal(data)

      await expect(polymerProver.validate(proof)).to.be.revertedWithCustomError(
        polymerProver,
        'InvalidTopicsLength',
      )
    })

    it('should revert if event signature is not correct', async (): Promise<void> => {
      topics = [
        badEventSignature,
        expectedHash,
        ethers.zeroPadValue(ethers.toBeHex(chainIds[0]), 32),
        ethers.zeroPadValue(claimant.address, 32),
      ]

      const topicsPacked = ethers.solidityPacked(
        ['bytes32', 'bytes32', 'bytes32', 'bytes32'],
        topics,
      )
      const inboxAddress = await inbox.getAddress()

      // set values for mock prover
      await testCrossL2ProverV2.setAll(
        chainIds[0],
        inboxAddress,
        topicsPacked,
        data,
      )

      // set values for mock proof index
      // start at 1 because we have already set the first index in constructor
      const proofIndex = 1
      const proof = ethers.zeroPadValue(ethers.toBeHex(proofIndex), 32)

      // get values from mock prover and ensure they are correct
      const [
        chainId_returned,
        emittingContract_returned,
        topics_returned,
        data_returned,
      ] = await testCrossL2ProverV2.validateEvent(proof)

      expect(chainId_returned).to.equal(chainIds[0])
      expect(emittingContract_returned).to.equal(inboxAddress)
      expect(topics_returned).to.equal(topicsPacked)
      expect(data_returned).to.equal(data)

      await expect(polymerProver.validate(proof)).to.be.revertedWithCustomError(
        polymerProver,
        'InvalidEventSignature',
      )
    })
  })

  describe('Batch emit', (): void => {
    let topics_0: string[]
    let topics_1: string[]
    let topics_2: string[]
    let topics_0_packed: string
    let topics_1_packed: string
    let topics_2_packed: string
    let data: string
    let expectedHash: string
    let expectedHash2: string
    let expectedHash3: string
    let eventSignature: string
    let inboxAddress: string

    beforeEach(async (): Promise<void> => {
      eventSignature = ethers.id('ToBeProven(bytes32,uint256,address)')
      expectedHash = '0x' + '11'.repeat(32)
      expectedHash2 = '0x' + '22'.repeat(32)
      expectedHash3 = '0x' + '33'.repeat(32)
      data = '0x'
      topics_0 = [
        eventSignature,
        expectedHash,
        ethers.zeroPadValue(ethers.toBeHex(chainIds[0]), 32),
        ethers.zeroPadValue(claimant.address, 32),
      ]
      topics_1 = [
        eventSignature,
        expectedHash2,
        ethers.zeroPadValue(ethers.toBeHex(chainIds[1]), 32),
        ethers.zeroPadValue(claimant2.address, 32),
      ]
      topics_2 = [
        eventSignature,
        expectedHash3,
        ethers.zeroPadValue(ethers.toBeHex(chainIds[0]), 32),
        ethers.zeroPadValue(claimant3.address, 32),
      ]
      topics_0_packed = ethers.solidityPacked(
        ['bytes32', 'bytes32', 'bytes32', 'bytes32'],
        topics_0,
      )
      topics_1_packed = ethers.solidityPacked(
        ['bytes32', 'bytes32', 'bytes32', 'bytes32'],
        topics_1,
      )
      topics_2_packed = ethers.solidityPacked(
        ['bytes32', 'bytes32', 'bytes32', 'bytes32'],
        topics_2,
      )
      inboxAddress = await inbox.getAddress()
    })

    it('should validate a batch of emits', async (): Promise<void> => {
      const proofIndex = [1, 2, 3]
      const proof = proofIndex.map((index) =>
        ethers.zeroPadValue(ethers.toBeHex(index), 32),
      )

      const chainIdsArray = [chainIds[0], chainIds[1], chainIds[0]]
      const emittingContractsArray = [inboxAddress, inboxAddress, inboxAddress]
      const topicsArray = [topics_0_packed, topics_1_packed, topics_2_packed]
      const dataArray = [data, data, data]

      for (let i = 0; i < proofIndex.length; i++) {
        await testCrossL2ProverV2.setAll(
          chainIdsArray[i],
          emittingContractsArray[i],
          topicsArray[i],
          dataArray[i],
        )
        let [
          chainId_returned,
          emittingContract_returned,
          topics_returned,
          data_returned,
        ] = await testCrossL2ProverV2.validateEvent(proof[i])

        expect(chainId_returned).to.equal(chainIdsArray[i])
        expect(emittingContract_returned).to.equal(emittingContractsArray[i])
        expect(topics_returned).to.equal(topicsArray[i])
        expect(data_returned).to.equal(dataArray[i])
      }

      await expect(polymerProver.validateBatch(proof))
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(expectedHash, claimant.address)
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(expectedHash2, claimant2.address)
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(expectedHash3, claimant3.address)
    })

    it('should validate a batch of emits and emit IntentAlreadyProven if one of the proofs is already proven', async (): Promise<void> => {
      const proofIndex = [1, 2, 3]
      const proof = proofIndex.map((index) =>
        ethers.zeroPadValue(ethers.toBeHex(index), 32),
      )

      const chainIdsArray = [chainIds[0], chainIds[1], chainIds[0]]
      const emittingContractsArray = [inboxAddress, inboxAddress, inboxAddress]
      const topicsArray = [topics_0_packed, topics_1_packed, topics_2_packed]
      const dataArray = [data, data, data]

      for (let i = 0; i < proofIndex.length; i++) {
        await testCrossL2ProverV2.setAll(
          chainIdsArray[i],
          emittingContractsArray[i],
          topicsArray[i],
          dataArray[i],
        )
        let [
          chainId_returned,
          emittingContract_returned,
          topics_returned,
          data_returned,
        ] = await testCrossL2ProverV2.validateEvent(proof[i])

        expect(chainId_returned).to.equal(chainIdsArray[i])
        expect(emittingContract_returned).to.equal(emittingContractsArray[i])
        expect(topics_returned).to.equal(topicsArray[i])
        expect(data_returned).to.equal(dataArray[i])
      }
      const proofIndexDuplicate = [1, 1, 2]
      const proofDuplicate = proofIndexDuplicate.map((index) =>
        ethers.zeroPadValue(ethers.toBeHex(index), 32),
      )

      await expect(polymerProver.validateBatch(proofDuplicate))
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(expectedHash, claimant.address)
        .to.emit(polymerProver, 'IntentAlreadyProven')
        .withArgs(expectedHash)
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(expectedHash2, claimant2.address)
    })
  })

  // describe('Packed emit', (): void => {
  //   let topics: string[]
  //   let topics_packed: string
  //   let data: string
  //   let expectedHash: string
  //   let expectedHash2: string
  //   let expectedHash3: string
  //   let eventSignature: string
  //   let inboxAddress: string
  //   let intentHashes: string[]
  //   let claimants: string[]
  //   let messageBody: string

  //   // beforeEach(async (): Promise<void> => {
  //   //   eventSignature = inbox.interface.getEvent('BatchToBeProven').topicHash
  //   //   expectedHash = '0x' + '11'.repeat(32)
  //   //   expectedHash2 = '0x' + '22'.repeat(32)
  //   //   expectedHash3 = '0x' + '33'.repeat(32)
  //   //   topics = [
  //   //     eventSignature,
  //   //     ethers.zeroPadValue(ethers.toBeHex(chainIds[0]), 32),
  //   //   ]

  //   //   topics_packed = ethers.solidityPacked(['bytes32', 'bytes32'], topics)
  //   //   inboxAddress = await inbox.getAddress()

  //   //   intentHashes = [expectedHash, expectedHash2, expectedHash3]
  //   //   claimants = [claimant.address, claimant.address, claimant2.address]

  //   //   const packedClaimant1 = ethers.solidityPacked(
  //   //     ['uint16', 'uint160', 'bytes32', 'bytes32'],
  //   //     [2, claimant.address, intentHashes[0], intentHashes[1]],
  //   //   )

  //   //   const packedClaimant2 = ethers.solidityPacked(
  //   //     ['uint16', 'uint160', 'bytes32'],
  //   //     [1, claimant2.address, intentHashes[2]],
  //   //   )

  //   //   messageBody = ethers.concat([packedClaimant1, packedClaimant2])
  //   // })

  //   // it('should validate a single packed emit', async (): Promise<void> => {
  //   //   // set values for mock prover
  //   //   await testCrossL2ProverV2.setAll(
  //   //     chainIds[0],
  //   //     inboxAddress,
  //   //     topics_packed,
  //   //     messageBody,
  //   //   )

  //   //   const proofIndex = 1
  //   //   const proof = ethers.zeroPadValue(ethers.toBeHex(proofIndex), 32)

  //   //   const [
  //   //     chainId_returned,
  //   //     emittingContract_returned,
  //   //     topics_returned,
  //   //     data_returned,
  //   //   ] = await testCrossL2ProverV2.validateEvent(proof)

  //   //   expect(chainId_returned).to.equal(chainIds[0])
  //   //   expect(emittingContract_returned).to.equal(inboxAddress)
  //   //   expect(topics_returned).to.equal(topics_packed)
  //   //   expect(data_returned).to.equal(messageBody)

  //   //   await expect(polymerProver.validatePacked(proof))
  //   //     .to.emit(polymerProver, 'IntentProven')
  //   //     .withArgs(intentHashes[0], claimants[0])
  //   //     .to.emit(polymerProver, 'IntentProven')
  //   //     .withArgs(intentHashes[1], claimants[1])
  //   //     .to.emit(polymerProver, 'IntentProven')
  //   //     .withArgs(intentHashes[2], claimants[2])
  //   // })

  //   // it('should emit IntentAlreadyProven if the intent is already proven', async (): Promise<void> => {
  //   //   intentHashes = [expectedHash, expectedHash2, expectedHash]
  //   //   claimants = [claimant.address, claimant2.address, claimant.address]

  //   //   const packedClaimant1 = ethers.solidityPacked(
  //   //     ['uint16', 'uint160', 'bytes32'],
  //   //     [1, claimant.address, intentHashes[0]],
  //   //   )

  //   //   const packedClaimant2 = ethers.solidityPacked(
  //   //     ['uint16', 'uint160', 'bytes32'],
  //   //     [1, claimant2.address, intentHashes[1]],
  //   //   )

  //   //   const packedClaimant3 = ethers.solidityPacked(
  //   //     ['uint16', 'uint160', 'bytes32'],
  //   //     [1, claimant.address, intentHashes[2]],
  //   //   )

  //   //   messageBody = ethers.concat([
  //   //     packedClaimant1,
  //   //     packedClaimant2,
  //   //     packedClaimant3,
  //   //   ])

  //   //   // set values for mock prover
  //   //   await testCrossL2ProverV2.setAll(
  //   //     chainIds[0],
  //   //     inboxAddress,
  //   //     topics_packed,
  //   //     messageBody,
  //   //   )

  //   //   const proofIndex = 1
  //   //   const proof = ethers.zeroPadValue(ethers.toBeHex(proofIndex), 32)

  //   //   await expect(polymerProver.validatePacked(proof))
  //   //     .to.emit(polymerProver, 'IntentProven')
  //   //     .withArgs(intentHashes[0], claimants[0])
  //   //     .to.emit(polymerProver, 'IntentProven')
  //   //     .withArgs(intentHashes[1], claimants[1])
  //   //     .to.emit(polymerProver, 'IntentAlreadyProven')
  //   //     .withArgs(intentHashes[0])
  //   // })

  //   // it('should revert for invalid emitting contract', async (): Promise<void> => {
  //   //   await testCrossL2ProverV2.setAll(
  //   //     chainIds[0],
  //   //     claimant.address,
  //   //     topics_packed,
  //   //     messageBody,
  //   //   )

  //   //   const proofIndex = 1
  //   //   const proof = ethers.zeroPadValue(ethers.toBeHex(proofIndex), 32)

  //   //   const [
  //   //     chainId_returned,
  //   //     emittingContract_returned,
  //   //     topics_returned,
  //   //     data_returned,
  //   //   ] = await testCrossL2ProverV2.validateEvent(proof)

  //   //   expect(chainId_returned).to.equal(chainIds[0])
  //   //   expect(emittingContract_returned).to.equal(claimant.address)
  //   //   expect(topics_returned).to.equal(topics_packed)
  //   //   expect(data_returned).to.equal(messageBody)

  //   //   await expect(
  //   //     polymerProver.validatePacked(proof),
  //   //   ).to.be.revertedWithCustomError(polymerProver, 'InvalidEmittingContract')
  //   // })

  //   it('should revert for invalid chainId', async (): Promise<void> => {
  //     const badChainId = 1234
  //     await testCrossL2ProverV2.setAll(
  //       badChainId,
  //       inboxAddress,
  //       topics_packed,
  //       messageBody,
  //     )

  //     const proofIndex = 1
  //     const proof = ethers.zeroPadValue(ethers.toBeHex(proofIndex), 32)

  //     const [
  //       chainId_returned,
  //       emittingContract_returned,
  //       topics_returned,
  //       data_returned,
  //     ] = await testCrossL2ProverV2.validateEvent(proof)

  //     expect(chainId_returned).to.equal(badChainId)
  //     expect(emittingContract_returned).to.equal(inboxAddress)
  //     expect(topics_returned).to.equal(topics_packed)
  //     expect(data_returned).to.equal(messageBody)

  //     await expect(
  //       polymerProver.validatePacked(proof),
  //     ).to.be.revertedWithCustomError(polymerProver, 'UnsupportedChainId')
  //   })

  //   it('should revert for topics length not 2', async (): Promise<void> => {
  //     topics = [
  //       eventSignature,
  //       expectedHash,
  //       ethers.zeroPadValue(ethers.toBeHex(chainIds[0]), 32),
  //     ]

  //     topics_packed = ethers.solidityPacked(
  //       ['bytes32', 'bytes32', 'bytes32'],
  //       topics,
  //     )

  //     await testCrossL2ProverV2.setAll(
  //       chainIds[0],
  //       inboxAddress,
  //       topics_packed,
  //       messageBody,
  //     )

  //     const proofIndex = 1
  //     const proof = ethers.zeroPadValue(ethers.toBeHex(proofIndex), 32)

  //     const [
  //       chainId_returned,
  //       emittingContract_returned,
  //       topics_returned,
  //       data_returned,
  //     ] = await testCrossL2ProverV2.validateEvent(proof)

  //     expect(chainId_returned).to.equal(chainIds[0])
  //     expect(emittingContract_returned).to.equal(inboxAddress)
  //     expect(topics_returned).to.equal(topics_packed)
  //     expect(data_returned).to.equal(messageBody)

  //     await expect(
  //       polymerProver.validatePacked(proof),
  //     ).to.be.revertedWithCustomError(polymerProver, 'InvalidTopicsLength')
  //   })

  //   it('should revert for invalid event signature', async (): Promise<void> => {
  //     const invalidEventSignature = ethers.id('ToBeProven(bytes)')
  //     topics = [
  //       invalidEventSignature,
  //       ethers.zeroPadValue(ethers.toBeHex(chainIds[0]), 32),
  //     ]

  //     topics_packed = ethers.solidityPacked(['bytes32', 'bytes32'], topics)

  //     await testCrossL2ProverV2.setAll(
  //       chainIds[0],
  //       inboxAddress,
  //       topics_packed,
  //       messageBody,
  //     )

  //     const proofIndex = 1
  //     const proof = ethers.zeroPadValue(ethers.toBeHex(proofIndex), 32)

  //     const [
  //       chainId_returned,
  //       emittingContract_returned,
  //       topics_returned,
  //       data_returned,
  //     ] = await testCrossL2ProverV2.validateEvent(proof)

  //     expect(chainId_returned).to.equal(chainIds[0])
  //     expect(emittingContract_returned).to.equal(inboxAddress)
  //     expect(topics_returned).to.equal(topics_packed)
  //     expect(data_returned).to.equal(messageBody)

  //     await expect(
  //       polymerProver.validatePacked(proof),
  //     ).to.be.revertedWithCustomError(polymerProver, 'InvalidEventSignature')
  //   })

  //   it('should allow a batch of packed emits to be proven', async (): Promise<void> => {
  //     const intentHashes1 = [expectedHash, expectedHash2, expectedHash3]
  //     const claimants1 = [claimant.address, claimant.address, claimant2.address]

  //     const packedHashes1 = ethers.solidityPacked(
  //       ['uint16', 'uint160', 'bytes32', 'bytes32'],
  //       [2, claimants1[0], intentHashes[0], intentHashes[1]],
  //     )

  //     const packedClaimant2 = ethers.solidityPacked(
  //       ['uint16', 'uint160', 'bytes32'],
  //       [1, claimants1[2], intentHashes[2]],
  //     )

  //     const messageBody1bytes = ethers.concat([packedHashes1, packedClaimant2])

  //     const expectedHash4 = '0x' + '44'.repeat(32)
  //     const expectedHash5 = '0x' + '55'.repeat(32)
  //     const expectedHash6 = '0x' + '66'.repeat(32)

  //     const intentHashes2 = [expectedHash4, expectedHash5, expectedHash6]
  //     const claimants2 = [
  //       claimant.address,
  //       claimant2.address,
  //       claimant3.address,
  //     ]

  //     const packedClaimant4 = ethers.solidityPacked(
  //       ['uint16', 'uint160', 'bytes32'],
  //       [1, claimants2[0], intentHashes2[0]],
  //     )

  //     const packedClaimant5 = ethers.solidityPacked(
  //       ['uint16', 'uint160', 'bytes32'],
  //       [1, claimants2[1], intentHashes2[1]],
  //     )

  //     const packedClaimant6 = ethers.solidityPacked(
  //       ['uint16', 'uint160', 'bytes32'],
  //       [1, claimants2[2], intentHashes2[2]],
  //     )

  //     const messageBody2bytes = ethers.concat([
  //       packedClaimant4,
  //       packedClaimant5,
  //       packedClaimant6,
  //     ])

  //     const proofIndex = [1, 2]
  //     const proofs = proofIndex.map((index) =>
  //       ethers.zeroPadValue(ethers.toBeHex(index), 32),
  //     )
  //     // set values for mock prover
  //     await testCrossL2ProverV2.setAll(
  //       chainIds[0],
  //       inboxAddress,
  //       topics_packed,
  //       messageBody1bytes,
  //     )

  //     let [
  //       chainId_returned1,
  //       emittingContract_returned1,
  //       topics_returned1,
  //       data_returned1,
  //     ] = await testCrossL2ProverV2.validateEvent(proofs[0])

  //     expect(chainId_returned1).to.equal(chainIds[0])
  //     expect(emittingContract_returned1).to.equal(inboxAddress)
  //     expect(topics_returned1).to.equal(topics_packed)
  //     expect(data_returned1).to.equal(messageBody1bytes)

  //     await testCrossL2ProverV2.setAll(
  //       chainIds[1],
  //       inboxAddress,
  //       topics_packed,
  //       messageBody2bytes,
  //     )

  //     let [
  //       chainId_returned2,
  //       emittingContract_returned2,
  //       topics_returned2,
  //       data_returned2,
  //     ] = await testCrossL2ProverV2.validateEvent(proofs[1])

  //     expect(chainId_returned2).to.equal(chainIds[1])
  //     expect(emittingContract_returned2).to.equal(inboxAddress)
  //     expect(topics_returned2).to.equal(topics_packed)
  //     expect(data_returned2).to.equal(messageBody2bytes)

  //     await expect(polymerProver.validateBatchPacked(proofs))
  //       .to.emit(polymerProver, 'IntentProven')
  //       .withArgs(intentHashes1[0], claimants1[0])
  //       .to.emit(polymerProver, 'IntentProven')
  //       .withArgs(intentHashes1[1], claimants1[1])
  //       .to.emit(polymerProver, 'IntentProven')
  //       .withArgs(intentHashes1[2], claimants1[2])
  //       .to.emit(polymerProver, 'IntentProven')
  //       .withArgs(intentHashes2[0], claimants2[0])
  //       .to.emit(polymerProver, 'IntentProven')
  //       .withArgs(intentHashes2[1], claimants2[1])
  //       .to.emit(polymerProver, 'IntentProven')
  //       .withArgs(intentHashes2[2], claimants2[2])
  //   })
  // })
  // describe('Packed emit and claim', (): void => {
  //   let topics: string[]
  //   let topics_packed: string
  //   let data: string
  //   let expectedHash: string
  //   let expectedHash2: string
  //   let expectedHash3: string
  //   let eventSignature: string
  //   let inboxAddress: string
  //   let intentHashes: string[]
  //   let claimants: string[]
  //   let messageBody: string
  //   let routeHashes: string[]
  //   let proverRewardArray: PolymerProver.ProverRewardStruct[]
  //   let rewardArray: Reward[]
  //   let polymerProverAddress: string
  //   let creator: string

  //   beforeEach(async (): Promise<void> => {
  //     eventSignature = inbox.interface.getEvent('BatchToBeProven').topicHash

  //     let routeHash1 = '0x' + '11'.repeat(32)
  //     let routeHash2 = '0x' + '22'.repeat(32)
  //     let routeHash3 = '0x' + '33'.repeat(32)
  //     topics = [
  //       eventSignature,
  //       ethers.zeroPadValue(ethers.toBeHex(chainIds[0]), 32),
  //     ]

  //     topics_packed = ethers.solidityPacked(['bytes32', 'bytes32'], topics)
  //     inboxAddress = await inbox.getAddress()

  //     routeHashes = [routeHash1, routeHash2, routeHash3]
  //     claimants = [claimant.address, claimant.address, claimant2.address]

  //     creator = claimant3.address
  //     polymerProverAddress = await polymerProver.getAddress()
  //     const tokenAddress = await token.getAddress()
  //     rewardArray = []
  //     intentHashes = []
  //     proverRewardArray = []

  //     for (let i = 0; i < claimants.length; i++) {
  //       const proverReward: PolymerProver.ProverRewardStruct = {
  //         creator: creator,
  //         deadline: 1111,
  //         nativeValue: BigInt(i + 1),
  //         tokens: [
  //           {
  //             token: tokenAddress,
  //             amount: 10 * (i + 1),
  //           },
  //         ],
  //       }

  //       const reward: Reward = {
  //         creator: creator,
  //         prover: polymerProverAddress,
  //         deadline: 1111,
  //         nativeValue: BigInt(i + 1),
  //         tokens: [
  //           {
  //             token: tokenAddress,
  //             amount: 10 * (i + 1),
  //           },
  //         ],
  //       }

  //       proverRewardArray.push(proverReward)
  //       rewardArray.push(reward)
  //       intentHashes.push(hashIntent(routeHashes[i], reward))
  //     }

  //     const packedClaimant1 = ethers.solidityPacked(
  //       ['uint16', 'uint160', 'bytes32', 'bytes32'],
  //       [2, claimant.address, intentHashes[0], intentHashes[1]],
  //     )

  //     const packedClaimant2 = ethers.solidityPacked(
  //       ['uint16', 'uint160', 'bytes32'],
  //       [1, claimant2.address, intentHashes[2]],
  //     )

  //     messageBody = ethers.concat([packedClaimant1, packedClaimant2])
  //   })

  //   it('should revert check size mismatch of route hashes and prover rewards', async (): Promise<void> => {})

  //   it('should revert for invalid emitting contract', async (): Promise<void> => {})

  //   it('should revert for invalid chainId', async (): Promise<void> => {})

  //   it('should revert for topics length not 2', async (): Promise<void> => {})

  //   it('should revert for invalid event signature', async (): Promise<void> => {})

  //   it('should allow a batch of packed emits to be proven', async (): Promise<void> => {})

  // })

  describe('messageBeforeClaim', (): void => {
    it('happy path should work', async (): Promise<void> => {})

    it('variations on happy path should work', async (): Promise<void> => {})

    it('should revert for truncated size', async (): Promise<void> => {})

    it('should revert for truncated claimant address', async (): Promise<void> => {})

    it('should revert for truncated intent set', async (): Promise<void> => {})

    it('should revert for size mismatch', async (): Promise<void> => {})
  })
})
