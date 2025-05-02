import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  PolyNativeProver,
  Inbox,
  TestCrossL2ProverV2,
  IntentSource,
  TestNativeProver,
} from '../typechain-types'
import { Reward, hashIntent, Intent, Route } from '../utils/intent'
import { keccak256 } from 'ethers'

export function calculateStorageSlot(intentHash: string): string {
  // Use the full Reward type for encoding, matching the Solidity abi.encode(reward)
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ['bytes32', 'uint256'],
      [intentHash, 1],
    ),
  )
}

describe('PolyNativeProver Test', (): void => {
  let polymerProver: PolyNativeProver
  let inbox: Inbox
  let testCrossL2ProverV2: TestCrossL2ProverV2
  let testNativeProver: TestNativeProver
  let intentSource: IntentSource
  let owner: SignerWithAddress
  let claimant: SignerWithAddress
  let claimant2: SignerWithAddress
  let claimant3: SignerWithAddress
  let chainIds: number[] = [10, 42161]
  let emptyTopics: string =
    '0x0000000000000000000000000000000000000000000000000000000000000000'
  let emptyData: string = '0x'

  let intent: Intent
  async function deployPolyNativeProverFixture(): Promise<{
    polymerProver: PolyNativeProver
    inbox: Inbox
    intentSource: IntentSource
    intent: Intent
    testCrossL2ProverV2: TestCrossL2ProverV2
    testNativeProver: TestNativeProver
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

    const testNativeProver = await (
      await ethers.getContractFactory('TestNativeProver')
    ).deploy()

    const polymerProver = await (
      await ethers.getContractFactory('PolyNativeProver')
    ).deploy(
      await testCrossL2ProverV2.getAddress(),
      await testNativeProver.getAddress(),
      await inbox.getAddress(),
      chainIds,
    )

    const intentSource = await (
      await ethers.getContractFactory('IntentSource')
    ).deploy()

    const srcChainId = (await ethers.provider.getNetwork()).chainId

    let route: Route = {
      salt: ethers.keccak256(ethers.toUtf8Bytes('testsalt')),
      source: Number(srcChainId),
      destination: chainIds[1],
      inbox: await inbox.getAddress(),
      tokens: [],
      calls: [],
    }

    const currentTimestamp = await time.latest() // Get the current blockchain timestamp

    let reward: Reward = {
      creator: owner.address,
      prover: await polymerProver.getAddress(),
      deadline: currentTimestamp + 3600, // Set deadline to 1 hour from now
      nativeValue: ethers.parseEther('1'),
      tokens: [],
    }

    intent = {
      reward,
      route,
    }

    return {
      polymerProver,
      intentSource,
      inbox,
      testCrossL2ProverV2,
      testNativeProver,
      intent,
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
      intentSource,
      inbox,
      testCrossL2ProverV2,
      testNativeProver,
      intent,
      owner,
      claimant,
      claimant2,
      claimant3,
    } = await loadFixture(deployPolyNativeProverFixture))
  })

  describe('Single emit for non-native path', (): void => {
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

      await expect(
        intentSource
          .connect(owner)
          .publishAndFund(intent, false, { value: ethers.parseEther('1') }),
      ).to.emit(intentSource, 'IntentFunded')
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

  describe('Single emit for native fallback path', (): void => {
    let intentHash: string
    const abiCoder = ethers.AbiCoder.defaultAbiCoder()
    let expectedStorageValue: string
    let happyPathProveArgs: any

    beforeEach(async (): Promise<void> => {
      intentHash = hashIntent(intent).intentHash

      const expectedStorageSlot = calculateStorageSlot(intentHash)
      expectedStorageValue = ethers.solidityPacked(
        ['address', 'uint96'],
        [claimant.address, ethers.parseUnits('1', 'ether')],
      )

      await testNativeProver.setAllowableStorage(expectedStorageValue)

      happyPathProveArgs = {
        chainID: chainIds[0],
        contractAddr: await inbox.getAddress(),
        storageSlot: expectedStorageSlot,
        storageValue: expectedStorageValue,
        l2WorldStateRoot: keccak256(ethers.toUtf8Bytes('world state route')),
      }
      await expect(
        intentSource
          .connect(owner)
          .publishAndFund(intent, false, { value: ethers.parseEther('1') }),
      ).to.emit(intentSource, 'IntentFunded')
    })

    const encodeProofData = async (proveArgs) => {
      const rlpEncodedL1Header = ethers.toUtf8Bytes('rlp l1 header')
      const rlpEncodedL2Header = ethers.toUtf8Bytes('rlp l2 header')
      const settledStateProof = ethers.toUtf8Bytes('settled state proof')
      const storageProof = [
        keccak256(ethers.toUtf8Bytes('storage proof root')),
        keccak256(ethers.toUtf8Bytes('storage proof')),
      ]
      const rlpEncodedAccount = ethers.toUtf8Bytes('RlpEncodedContractAccount')
      const l2AccountProof = [
        ethers.toUtf8Bytes('L2AccountProof1'),
        ethers.toUtf8Bytes('0xL2AccountProof2'),
      ]

      const proofBytes = abiCoder.encode(
        [
          'tuple(uint256 chainID, address contractAddr, bytes32 storageSlot, bytes32 storageValue, bytes32 l2WorldStateRoot)',
          'bytes',
          'bytes',
          'bytes',
          'bytes[]',
          'bytes',
          'bytes[]',
        ],
        [
          proveArgs,
          rlpEncodedL1Header,
          rlpEncodedL2Header,
          settledStateProof,
          storageProof,
          rlpEncodedAccount,
          l2AccountProof,
        ],
      )

      // get values from mock prover and ensure they are correct
      if (proveArgs.storageValue == expectedStorageValue) {
        const { chainId, storingContract, storageValue } =
          await testNativeProver.prove(
            proveArgs,
            rlpEncodedL1Header,
            rlpEncodedL2Header,
            settledStateProof,
            storageProof,
            rlpEncodedAccount,
            l2AccountProof,
          )

        expect(chainId).to.equal(proveArgs.chainID)
        expect(storingContract).to.equal(proveArgs.contractAddr)
        expect(storageValue).to.equal(proveArgs.storageValue)
      }
      return proofBytes
    }

    it('should validate a single storage proof', async (): Promise<void> => {
      const proofBytes = await encodeProofData(happyPathProveArgs)
      await expect(polymerProver.validateNative(proofBytes, intentHash))
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(intentHash, claimant.address)
    })

    it('should emit IntentAlreadyProven if the proof is already proven', async (): Promise<void> => {
      const proofBytes = await encodeProofData(happyPathProveArgs)
      await expect(polymerProver.validateNative(proofBytes, intentHash))
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(intentHash, claimant.address)

      await expect(polymerProver.validateNative(proofBytes, intentHash))
        .to.emit(polymerProver, 'IntentAlreadyProven')
        .withArgs(intentHash)
    })

    it('should revert if inbox contract is not the contract being read from', async (): Promise<void> => {
      const proofData = {
        ...happyPathProveArgs,
        contractAddr: owner.address,
      }
      const proofBytes = await encodeProofData(proofData)

      await expect(
        polymerProver.validateNative(proofBytes, intentHash),
      ).to.be.revertedWithCustomError(polymerProver, 'InvalidEmittingContract')
    })

    it('should revert if chainId is not supported', async (): Promise<void> => {
      const proveArgs = {
        ...happyPathProveArgs,
        chainID: 12312,
      }
      const proofBytes = await encodeProofData(proveArgs)
      await expect(
        polymerProver.validateNative(proofBytes, intentHash),
      ).to.be.revertedWithCustomError(polymerProver, 'UnsupportedChainId')
    })

    it('should revert if the wrong storage slot is used', async (): Promise<void> => {
      const invalidRoute = { ...intent.route, chainId: 123123 }
      const invalidIntent = { reward: intent.reward, route: invalidRoute }
      const invalidIntentHash = hashIntent(invalidIntent)
      const proofBytes = await encodeProofData({
        ...happyPathProveArgs,
        storageSlot: ethers.zeroPadValue(ethers.toBeHex(27), 32),
      })
      await expect(
        polymerProver.validateNative(proofBytes, invalidIntentHash.intentHash),
      ).to.be.revertedWithCustomError(polymerProver, 'IncorrectStorageSlot')
    })

    it('should revert if the wrong storage value is used', async (): Promise<void> => {
      const invalidRoute = { ...intent.route, chainId: 123123 }
      const invalidIntent = { reward: intent.reward, route: invalidRoute }
      const invalidIntentHash = hashIntent(invalidIntent)
      const proofBytes = await encodeProofData({
        ...happyPathProveArgs,
        storageValue: ethers.zeroPadValue(ethers.toBeHex(0), 32),
      })
      await expect(
        polymerProver.validateNative(proofBytes, invalidIntentHash.intentHash),
      ).to.be.reverted
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
})
