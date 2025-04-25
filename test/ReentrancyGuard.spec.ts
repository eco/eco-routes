import { expect } from 'chai'
import { ethers } from 'hardhat'
import { Contract, ContractFactory, Signer } from 'ethers'
import { parseEther } from 'ethers/lib/utils'
import { hashIntent, TokenAmount } from '../utils/intent'
import { Intent, Route, Reward, Call } from '../utils/EcoERC7683'
import { testData, getTestData, generateRandomAddress } from './testData'
import { loadFixture } from '@nomicfoundation/hardhat-network-helpers'

/**
 * This test suite focuses on testing the protocol's resilience against reentrancy attacks,
 * particularly during token transfers in cross-chain operations.
 */
describe('Reentrancy Protection', () => {
  let intentSource: Contract
  let inbox: Contract
  let hyperProver: Contract
  let metaProver: Contract
  let maliciousToken: Contract
  let legitimateToken: Contract
  let attacker: Signer
  let deployer: Signer
  let user: Signer
  let solver: Signer

  async function deployContractsFixture() {
    const signers = await ethers.getSigners()
    deployer = signers[0]
    user = signers[1]
    solver = signers[2]
    attacker = signers[3]

    // Deploy test tokens
    const legitimateTokenFactory = await ethers.getContractFactory('TestERC20')
    legitimateToken = await legitimateTokenFactory.deploy('Legitimate', 'LEGIT')

    // Deploy malicious token with reentrancy attack capabilities
    const maliciousTokenFactory = await ethers.getContractFactory('BadERC20')
    maliciousToken = await maliciousTokenFactory.deploy('Malicious', 'ATTACK')

    // Mock mailbox for Hyperlane
    const TestMailboxFactory = await ethers.getContractFactory('TestMailbox')
    const mailbox = await TestMailboxFactory.deploy()

    // Mock router for Metalayer
    const TestMetaRouterFactory =
      await ethers.getContractFactory('TestMetaRouter')
    const metaRouter = await TestMetaRouterFactory.deploy()

    // Deploy IntentSource
    const IntentSourceFactory = await ethers.getContractFactory('IntentSource')
    intentSource = await IntentSourceFactory.deploy()

    // Deploy Inbox
    const InboxFactory = await ethers.getContractFactory('Inbox')
    inbox = await InboxFactory.deploy()
    await inbox.initialize()

    // Deploy HyperProver
    const HyperProverFactory = await ethers.getContractFactory('HyperProver')
    hyperProver = await HyperProverFactory.deploy(
      mailbox.address,
      inbox.address,
      [await solver.getAddress()],
    )

    // Deploy MetaProver
    const MetaProverFactory = await ethers.getContractFactory('MetaProver')
    metaProver = await MetaProverFactory.deploy(
      metaRouter.address,
      inbox.address,
      [await solver.getAddress()],
    )

    // Initialize contracts and connections
    await intentSource.initialize()
    await inbox.setProvers([hyperProver.address, metaProver.address])
    await inbox.makeSolvingPublic()

    // Mint tokens to user
    await legitimateToken.mint(await user.getAddress(), parseEther('100'))
    await maliciousToken.mint(await user.getAddress(), parseEther('100'))

    return {
      intentSource,
      inbox,
      hyperProver,
      metaProver,
      legitimateToken,
      maliciousToken,
    }
  }

  beforeEach(async () => {
    const contracts = await loadFixture(deployContractsFixture)
    intentSource = contracts.intentSource
    inbox = contracts.inbox
    hyperProver = contracts.hyperProver
    metaProver = contracts.metaProver
    legitimateToken = contracts.legitimateToken
    maliciousToken = contracts.maliciousToken
  })

  describe('Token Transfer Reentrancy Protection', () => {
    it('should prevent reentrancy attacks during token transfers', async () => {
      // Configure malicious token to attempt reentrancy
      await maliciousToken
        .connect(attacker)
        .configureAttack(intentSource.address, 'publishAndFund')

      // Setup intent with malicious token as reward
      const route: Route = {
        salt: ethers.utils.randomBytes(32),
        source: 31337, // Hardhat network chainId
        destination: 31338, // Mocked destination chain
        inbox: inbox.address,
        tokens: [],
        calls: [],
      }

      const reward: Reward = {
        creator: await user.getAddress(),
        prover: hyperProver.address,
        deadline: Math.floor(Date.now() / 1000) + 3600, // 1 hour from now
        nativeValue: 0,
        tokenAmounts: [
          {
            token: maliciousToken.address,
            amount: parseEther('10'),
          },
        ],
      }

      const intent: Intent = { route, reward }

      // Approve tokens from user to IntentSource
      await maliciousToken
        .connect(user)
        .approve(intentSource.address, parseEther('10'))

      // Publish intent - this should not allow reentrancy
      await expect(
        intentSource.connect(user).publishAndFund(intent, { value: 0 }),
      ).to.be.revertedWith('ReentrancyGuard: reentrant call')
    })

    it('should handle normal token transfers correctly', async () => {
      // Setup intent with legitimate token as reward
      const route: Route = {
        salt: ethers.utils.randomBytes(32),
        source: 31337, // Hardhat network chainId
        destination: 31338, // Mocked destination chain
        inbox: inbox.address,
        tokens: [],
        calls: [],
      }

      const reward: Reward = {
        creator: await user.getAddress(),
        prover: hyperProver.address,
        deadline: Math.floor(Date.now() / 1000) + 3600, // 1 hour from now
        nativeValue: 0,
        tokenAmounts: [
          {
            token: legitimateToken.address,
            amount: parseEther('10'),
          },
        ],
      }

      const intent: Intent = { route, reward }

      // Approve tokens from user to IntentSource
      await legitimateToken
        .connect(user)
        .approve(intentSource.address, parseEther('10'))

      // Publish intent - this should work fine
      await expect(
        intentSource.connect(user).publishAndFund(intent, { value: 0 }),
      ).to.not.be.reverted

      // Verify intent was published and funded
      const intentHash = await hashIntent(intent)
      expect(await intentSource.isIntentFunded(intent)).to.be.true
    })
  })
})
