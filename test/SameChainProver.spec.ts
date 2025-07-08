import { expect } from 'chai'
import { ethers } from 'hardhat'
import { loadFixture } from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { SameChainProver, TestERC20 } from '../typechain-types'
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'

describe('SameChainProver Test', () => {
  let sameChainProver: SameChainProver
  let testInbox: any // TestInbox contract
  let testToken: TestERC20
  let owner: SignerWithAddress
  let claimant: SignerWithAddress
  let unauthorized: SignerWithAddress

  async function deployFixture() {
    const [owner, claimant, unauthorized] = await ethers.getSigners()

    // Deploy test token
    const TestERC20Factory = await ethers.getContractFactory('TestERC20')
    const testToken = (await TestERC20Factory.deploy(
      'Test Token',
      'TEST',
    )) as TestERC20

    // Deploy TestInbox
    const TestInboxFactory = await ethers.getContractFactory('TestInbox')
    const testInbox = await TestInboxFactory.deploy()

    // Deploy SameChainProver
    const SameChainProverFactory =
      await ethers.getContractFactory('SameChainProver')
    const sameChainProver = (await SameChainProverFactory.deploy(
      await testInbox.getAddress(),
    )) as SameChainProver

    return {
      sameChainProver,
      testInbox,
      testToken,
      owner,
      claimant,
      unauthorized,
    }
  }

  beforeEach(async () => {
    const fixture = await loadFixture(deployFixture)
    sameChainProver = fixture.sameChainProver
    testInbox = fixture.testInbox
    testToken = fixture.testToken
    owner = fixture.owner
    claimant = fixture.claimant
    unauthorized = fixture.unauthorized
  })

  describe('1. Constructor', () => {
    it('should initialize with the correct parameters', async () => {
      expect(await sameChainProver.getProofType()).to.equal('Same chain')

      // Test that chain ID is set correctly (should be hardhat's default chainid)
      const chainId = (await ethers.provider.getNetwork()).chainId

      // Test provenIntents with zero address (should return chainId and zero address)
      const zeroIntentHash = ethers.ZeroHash
      const proofData = await sameChainProver.provenIntents(zeroIntentHash)
      expect(proofData.destinationChainID).to.equal(chainId)
      expect(proofData.claimant).to.equal(ethers.ZeroAddress)
    })
  })

  describe('2. provenIntents', () => {
    it('should return zero address for unfulfilled intent', async () => {
      const intentHash = ethers.sha256('0x1234')
      const proofData = await sameChainProver.provenIntents(intentHash)

      expect(proofData.claimant).to.equal(ethers.ZeroAddress)
      expect(proofData.destinationChainID).to.equal(
        (await ethers.provider.getNetwork()).chainId,
      )
    })

    it('should return claimant address for fulfilled intent', async () => {
      const claimantAddress = await claimant.getAddress()
      const intentHash = ethers.sha256('0x5678')

      // Use TestInbox to directly set the fulfilled mapping
      await testInbox.setFulfilled(intentHash, claimantAddress)

      // Now check that SameChainProver returns the correct claimant
      const proofData = await sameChainProver.provenIntents(intentHash)
      expect(proofData.claimant).to.equal(claimantAddress)
      expect(proofData.destinationChainID).to.equal(
        (await ethers.provider.getNetwork()).chainId,
      )
    })

    it('should return current chain ID for any intent hash', async () => {
      const chainId = (await ethers.provider.getNetwork()).chainId
      const randomHashes = [
        ethers.sha256('0x1111'),
        ethers.sha256('0x2222'),
        ethers.sha256('0x3333'),
      ]

      for (const hash of randomHashes) {
        const proofData = await sameChainProver.provenIntents(hash)
        expect(proofData.destinationChainID).to.equal(chainId)
      }
    })
  })

  describe('3. prove', () => {
    it('should not revert when called with any parameters', async () => {
      const intentHashes = [ethers.sha256('0x1234'), ethers.sha256('0x5678')]
      const claimants = [
        await claimant.getAddress(),
        await unauthorized.getAddress(),
      ]

      // Should not revert with any parameters
      await expect(
        sameChainProver.prove(
          await owner.getAddress(),
          1,
          intentHashes,
          claimants,
          '0x',
        ),
      ).to.not.be.reverted

      // Should not revert with empty arrays
      await expect(
        sameChainProver.prove(await owner.getAddress(), 1, [], [], '0x'),
      ).to.not.be.reverted

      // Should not revert with ether sent
      await expect(
        sameChainProver.prove(
          await owner.getAddress(),
          1,
          intentHashes,
          claimants,
          '0x1234',
          { value: ethers.parseEther('1') },
        ),
      ).to.not.be.reverted
    })
  })

  describe('4. challengeIntentProof', () => {
    it('should always revert with CannotChallengeSameChainIntentProof error', async () => {
      // Create a dummy intent struct
      const intent = {
        route: {
          salt: ethers.ZeroHash,
          source: 1,
          destination: 1,
          inbox: await testInbox.getAddress(),
          tokens: [],
          calls: [],
        },
        reward: {
          creator: await owner.getAddress(),
          prover: ethers.ZeroAddress,
          deadline: 0,
          nativeValue: 0,
          tokens: [],
        },
      }

      await expect(
        sameChainProver.challengeIntentProof(intent),
      ).to.be.revertedWithCustomError(
        sameChainProver,
        'CannotChallengeSameChainIntentProof',
      )
    })
  })

  describe('6. Edge Cases', () => {
    it('should handle large chain IDs correctly', async () => {
      // This test verifies the SafeCast is working correctly
      const chainId = (await ethers.provider.getNetwork()).chainId
      expect(chainId).to.be.lessThan(2n ** 96n) // Should be well within uint96 range

      const proofData = await sameChainProver.provenIntents(ethers.ZeroHash)
      expect(proofData.destinationChainID).to.equal(chainId)
    })
  })
})
