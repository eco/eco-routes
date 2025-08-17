import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  PolymerProver,
  Portal,
  TestCrossL2ProverV2,
  IIntentSource,
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

describe('PolymerProver Test', (): void => {
  let polymerProver: PolymerProver
  let portal: Portal
  let testCrossL2ProverV2: TestCrossL2ProverV2
  let intentSource: IIntentSource
  let owner: SignerWithAddress
  let claimant: SignerWithAddress
  let claimant2: SignerWithAddress
  let claimant3: SignerWithAddress
  let destinationProver: string
  let chainIds: number[] = [10, 42161]
  let emptyTopics: string =
    '0x0000000000000000000000000000000000000000000000000000000000000000'
  let emptyData: string = '0x'

  let intent: Intent
  async function deployPolymerProverFixture(): Promise<{
    polymerProver: PolymerProver
    portal: Portal
    intentSource: IIntentSource
    intent: Intent
    testCrossL2ProverV2: TestCrossL2ProverV2
    destinationProver: string
    owner: SignerWithAddress
    solver: SignerWithAddress
    claimant: SignerWithAddress
    claimant2: SignerWithAddress
    claimant3: SignerWithAddress
    token: SignerWithAddress
  }> {
    const [owner, solver, claimant, claimant2, claimant3, token] =
      await ethers.getSigners()

    const portal = await (await ethers.getContractFactory('Portal')).deploy()

    const testCrossL2ProverV2 = await (
      await ethers.getContractFactory('TestCrossL2ProverV2')
    ).deploy(chainIds[0], await portal.getAddress(), emptyTopics, emptyData)

    const destinationProver = '0x1234567890123456789012345678901234567890'

    const polymerProver = await (
      await ethers.getContractFactory('PolymerProver')
    ).deploy(
      owner.address, // owner
      await portal.getAddress(),
    )

    // Initialize with CrossL2ProverV2 and whitelist
    const whitelistChainIds = [chainIds[0], chainIds[1]]
    const provers = [
      ethers.zeroPadValue(destinationProver, 32),
      ethers.zeroPadValue(destinationProver, 32),
    ]

    await polymerProver.initialize(
      await testCrossL2ProverV2.getAddress(),
      whitelistChainIds,
      provers,
    )

    // Use the IIntentSource interface with the Portal implementation
    const intentSource = await ethers.getContractAt(
      'IIntentSource',
      await portal.getAddress(),
    )

    const srcChainId = (await ethers.provider.getNetwork()).chainId

    const currentTimestamp = await time.latest() // Get the current blockchain timestamp

    let route: Route = {
      salt: ethers.keccak256(ethers.toUtf8Bytes('testsalt')),
      deadline: currentTimestamp + 3600, // Set deadline to 1 hour from now
      portal: await portal.getAddress(),
      tokens: [],
      calls: [],
    }

    let reward: Reward = {
      creator: owner.address,
      prover: await polymerProver.getAddress(),
      deadline: currentTimestamp + 3600, // Set deadline to 1 hour from now
      nativeAmount: ethers.parseEther('1'),
      tokens: [],
    }

    intent = {
      destination: chainIds[1],
      route,
      reward,
    }

    return {
      polymerProver,
      intentSource,
      portal,
      testCrossL2ProverV2,
      intent,
      destinationProver,
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
      portal,
      testCrossL2ProverV2,
      intent,
      destinationProver,
      owner,
      claimant,
      claimant2,
      claimant3,
    } = await loadFixture(deployPolymerProverFixture))
  })

  describe('Single emit for non-native path', (): void => {
    let topics: string[]
    let data: string
    let expectedHash: string
    let eventSignature: string
    let badEventSignature: string

    beforeEach(async (): Promise<void> => {
      eventSignature = ethers.id('IntentFulfilledFromSource(uint64,bytes)')
      badEventSignature = ethers.id('BadEventSignature(uint64,bytes)')
      expectedHash = '0x' + '11'.repeat(32)

      data = ethers.solidityPacked(
        ['bytes32', 'bytes32'],
        [expectedHash, ethers.zeroPadValue(claimant.address, 32)],
      )

      topics = [
        eventSignature,
        ethers.zeroPadValue(
          ethers.toBeHex(
            await ethers.provider.getNetwork().then((n) => n.chainId),
          ),
          32,
        ),
      ]

      await expect(
        intentSource
          .connect(owner)
          .publishAndFund(intent, false, { value: ethers.parseEther('1') }),
      ).to.emit(intentSource, 'IntentFunded')
    })

    it('should validate a single emit', async (): Promise<void> => {
      const topicsPacked = ethers.solidityPacked(['bytes32', 'bytes32'], topics)
      // set values for mock prover using the whitelisted destination prover
      await testCrossL2ProverV2.setAll(
        chainIds[0],
        destinationProver,
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
      expect(emittingContract_returned).to.equal(destinationProver)
      expect(topics_returned).to.equal(topicsPacked)
      expect(data_returned).to.equal(data)

      await expect(polymerProver.validate(proof))
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(expectedHash, claimant.address, chainIds[0])
    })

    it('should emit IntentAlreadyProven if the proof is already proven', async (): Promise<void> => {
      const topicsPacked = ethers.solidityPacked(['bytes32', 'bytes32'], topics)
      // set values for mock prover using the whitelisted destination prover
      await testCrossL2ProverV2.setAll(
        chainIds[0],
        destinationProver,
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
      expect(emittingContract_returned).to.equal(destinationProver)
      expect(topics_returned).to.equal(topicsPacked)
      expect(data_returned).to.equal(data)

      await expect(polymerProver.validate(proof))
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(expectedHash, claimant.address, chainIds[0])

      await expect(polymerProver.validate(proof))
        .to.emit(polymerProver, 'IntentAlreadyProven')
        .withArgs(expectedHash)
    })

    it('should revert if inbox contract is not the emitting contract', async (): Promise<void> => {
      const topicsPacked = ethers.solidityPacked(['bytes32', 'bytes32'], topics)

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

    it('should revert if topics length is not 2', async (): Promise<void> => {
      topics = [
        eventSignature,
        // missing source chain ID topic
      ]

      const topicsPacked = ethers.solidityPacked(['bytes32'], topics)
      // set values for mock prover using the whitelisted destination prover
      await testCrossL2ProverV2.setAll(
        chainIds[0],
        destinationProver,
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
      expect(emittingContract_returned).to.equal(destinationProver)
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
        ethers.zeroPadValue(
          ethers.toBeHex(
            await ethers.provider.getNetwork().then((n) => n.chainId),
          ),
          32,
        ),
      ]

      const topicsPacked = ethers.solidityPacked(['bytes32', 'bytes32'], topics)
      // set values for mock prover using the whitelisted destination prover
      await testCrossL2ProverV2.setAll(
        chainIds[0],
        destinationProver,
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
      expect(emittingContract_returned).to.equal(destinationProver)
      expect(topics_returned).to.equal(topicsPacked)
      expect(data_returned).to.equal(data)

      await expect(polymerProver.validate(proof)).to.be.revertedWithCustomError(
        polymerProver,
        'InvalidEventSignature',
      )
    })

    it('should validate multiple intents in a single event', async (): Promise<void> => {
      const expectedHash1 = '0x' + '11'.repeat(32)
      const expectedHash2 = '0x' + '22'.repeat(32)
      const expectedHash3 = '0x' + '33'.repeat(32)

      const multipleIntentsData = ethers.solidityPacked(
        ['bytes32', 'bytes32', 'bytes32', 'bytes32', 'bytes32', 'bytes32'],
        [
          expectedHash1,
          ethers.zeroPadValue(claimant.address, 32),
          expectedHash2,
          ethers.zeroPadValue(claimant2.address, 32),
          expectedHash3,
          ethers.zeroPadValue(claimant3.address, 32),
        ],
      )

      const topicsPacked = ethers.solidityPacked(
        ['bytes32', 'bytes32'],
        [
          eventSignature,
          ethers.zeroPadValue(
            ethers.toBeHex(
              await ethers.provider.getNetwork().then((n) => n.chainId),
            ),
            32,
          ),
        ],
      )

      await testCrossL2ProverV2.setAll(
        chainIds[0],
        destinationProver,
        topicsPacked,
        multipleIntentsData,
      )

      const proofIndex = 1
      const proof = ethers.zeroPadValue(ethers.toBeHex(proofIndex), 32)

      await expect(polymerProver.validate(proof))
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(expectedHash1, claimant.address, chainIds[0])
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(expectedHash2, claimant2.address, chainIds[0])
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(expectedHash3, claimant3.address, chainIds[0])
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
    let destinationProverAddress: string

    beforeEach(async (): Promise<void> => {
      eventSignature = ethers.id('IntentFulfilledFromSource(uint64,bytes)')
      expectedHash = '0x' + '11'.repeat(32)
      expectedHash2 = '0x' + '22'.repeat(32)
      expectedHash3 = '0x' + '33'.repeat(32)
      const chainId = await ethers.provider.getNetwork().then((n) => n.chainId)

      topics_0 = [
        eventSignature,
        ethers.zeroPadValue(ethers.toBeHex(chainId), 32),
      ]
      topics_1 = [
        eventSignature,
        ethers.zeroPadValue(ethers.toBeHex(chainId), 32),
      ]
      topics_2 = [
        eventSignature,
        ethers.zeroPadValue(ethers.toBeHex(chainId), 32),
      ]
      topics_0_packed = ethers.solidityPacked(['bytes32', 'bytes32'], topics_0)
      topics_1_packed = ethers.solidityPacked(['bytes32', 'bytes32'], topics_1)
      topics_2_packed = ethers.solidityPacked(['bytes32', 'bytes32'], topics_2)
      destinationProverAddress = destinationProver
    })

    it('should validate a batch of emits', async (): Promise<void> => {
      const proofIndex = [1, 2, 3]
      const proof = proofIndex.map((index) =>
        ethers.zeroPadValue(ethers.toBeHex(index), 32),
      )

      const chainIdsArray = [chainIds[0], chainIds[1], chainIds[0]]
      const emittingContractsArray = [
        destinationProverAddress,
        destinationProverAddress,
        destinationProverAddress,
      ]
      const topicsArray = [topics_0_packed, topics_1_packed, topics_2_packed]
      const data_0 = ethers.solidityPacked(
        ['bytes32', 'bytes32'],
        [expectedHash, ethers.zeroPadValue(claimant.address, 32)],
      )
      const data_1 = ethers.solidityPacked(
        ['bytes32', 'bytes32'],
        [expectedHash2, ethers.zeroPadValue(claimant2.address, 32)],
      )
      const data_2 = ethers.solidityPacked(
        ['bytes32', 'bytes32'],
        [expectedHash3, ethers.zeroPadValue(claimant3.address, 32)],
      )
      const dataArray = [data_0, data_1, data_2]

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
        .withArgs(expectedHash, claimant.address, chainIds[0])
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(expectedHash2, claimant2.address, chainIds[1])
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(expectedHash3, claimant3.address, chainIds[0])
    })

    it('should validate a batch of emits and emit IntentAlreadyProven if one of the proofs is already proven', async (): Promise<void> => {
      const proofIndex = [1, 2, 3]
      const proof = proofIndex.map((index) =>
        ethers.zeroPadValue(ethers.toBeHex(index), 32),
      )

      const chainIdsArray = [chainIds[0], chainIds[1], chainIds[0]]
      const emittingContractsArray = [
        destinationProverAddress,
        destinationProverAddress,
        destinationProverAddress,
      ]
      const topicsArray = [topics_0_packed, topics_1_packed, topics_2_packed]
      const data_0 = ethers.solidityPacked(
        ['bytes32', 'bytes32'],
        [expectedHash, ethers.zeroPadValue(claimant.address, 32)],
      )
      const data_1 = ethers.solidityPacked(
        ['bytes32', 'bytes32'],
        [expectedHash2, ethers.zeroPadValue(claimant2.address, 32)],
      )
      const data_2 = ethers.solidityPacked(
        ['bytes32', 'bytes32'],
        [expectedHash3, ethers.zeroPadValue(claimant3.address, 32)],
      )
      const dataArray = [data_0, data_1, data_2]

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
        .withArgs(expectedHash, claimant.address, chainIds[0])
        .to.emit(polymerProver, 'IntentAlreadyProven')
        .withArgs(expectedHash)
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(expectedHash2, claimant2.address, chainIds[1])
    })
  })
})
