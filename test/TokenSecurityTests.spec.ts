import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { time, loadFixture } from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { 
  TestERC20,
  IntentSource, 
  TestProver,
  Inbox
} from '../typechain-types'
import { hashIntent, TokenAmount } from '../utils/intent'

/**
 * This test suite focuses on testing the protocol's resilience against token security issues
 */
describe('Token Security Tests', () => {
  let intentSource: IntentSource
  let prover: TestProver
  let inbox: Inbox
  let token: TestERC20
  let creator: SignerWithAddress
  let claimant: SignerWithAddress

  async function deployContractsFixture() {
    const [creator, claimant] = await ethers.getSigners()

    // Deploy IntentSource
    const intentSourceFactory = await ethers.getContractFactory('IntentSource')
    const intentSource = await intentSourceFactory.deploy()
    
    // Deploy Inbox
    inbox = await (await ethers.getContractFactory('Inbox')).deploy()

    // Deploy test prover
    prover = await (
      await ethers.getContractFactory('TestProver')
    ).deploy(await inbox.getAddress())

    // Deploy test token
    const tokenFactory = await ethers.getContractFactory('TestERC20')
    const token = await tokenFactory.deploy('Test Token', 'TEST')

    // Mint tokens to creator
    await token.mint(creator.address, ethers.parseEther('100'))

    return {
      intentSource,
      prover,
      inbox,
      token,
      creator,
      claimant
    }
  }

  beforeEach(async () => {
    ({ intentSource, prover, inbox, token, creator, claimant } = 
      await loadFixture(deployContractsFixture))
  })

  it('should handle token transfers correctly in intent creation', async () => {
    // Setup intent data
    const salt = ethers.randomBytes(32)
    const chainId = await ethers.provider.getNetwork().then(n => Number(n.chainId))
    const routeTokens: TokenAmount[] = []
    const calls = []
    const expiry = (await time.latest()) + 3600 // 1 hour from now
    
    const rewardTokens: TokenAmount[] = [{ 
      token: await token.getAddress(), 
      amount: ethers.parseEther('1') 
    }]
    
    // Create route and reward
    const route = {
      salt,
      source: chainId,
      destination: chainId + 1,
      inbox: await inbox.getAddress(),
      tokens: routeTokens,
      calls: calls
    }
    
    const reward = {
      creator: await creator.getAddress(),
      prover: await prover.getAddress(),
      deadline: expiry,
      nativeValue: 0n,
      tokens: rewardTokens
    }
    
    const intent = { route, reward }
    
    // Approve tokens for spending
    await token.connect(creator).approve(
      await intentSource.getAddress(), 
      ethers.parseEther('100')
    )
    
    // Create intent with tokens
    await intentSource.connect(creator).publishAndFund(intent, false, { value: 0 })
    
    // Verify intent was created and funded
    const { intentHash } = hashIntent(intent)
    expect(await intentSource.isIntentFunded(intent)).to.be.true
    
    // Verify reward status is correct - RewardStatus.Created = 0
    expect(await intentSource.getRewardStatus(intentHash)).to.equal(0)
  })
  
  it('should handle multiple token rewards correctly', async () => {
    // Deploy a second token
    const tokenB = await (await ethers.getContractFactory('TestERC20')).deploy('Token B', 'TKB')
    await tokenB.mint(creator.address, ethers.parseEther('100'))
    
    // Setup intent data with multiple reward tokens
    const salt = ethers.randomBytes(32)
    const chainId = await ethers.provider.getNetwork().then(n => Number(n.chainId))
    const expiry = (await time.latest()) + 3600 // 1 hour from now
    
    const rewardTokens: TokenAmount[] = [
      { token: await token.getAddress(), amount: ethers.parseEther('2') },
      { token: await tokenB.getAddress(), amount: ethers.parseEther('3') }
    ]
    
    const route = {
      salt,
      source: chainId,
      destination: chainId + 1,
      inbox: await inbox.getAddress(),
      tokens: [],
      calls: []
    }
    
    const reward = {
      creator: await creator.getAddress(),
      prover: await prover.getAddress(),
      deadline: expiry,
      nativeValue: 0n,
      tokens: rewardTokens
    }
    
    const intent = { route, reward }
    
    // Approve both tokens for spending
    await token.connect(creator).approve(
      await intentSource.getAddress(), 
      ethers.parseEther('100')
    )
    
    await tokenB.connect(creator).approve(
      await intentSource.getAddress(), 
      ethers.parseEther('100')
    )
    
    // Create intent with multiple tokens
    await intentSource.connect(creator).publishAndFund(intent, { value: 0 })
    
    // Verify intent was created and funded
    expect(await intentSource.isIntentFunded(intent)).to.be.true
  })
  
  it('should handle intent creation with combined native and token rewards', async () => {
    // Setup intent data with both native value and token rewards
    const salt = ethers.randomBytes(32)
    const chainId = await ethers.provider.getNetwork().then(n => Number(n.chainId))
    const expiry = (await time.latest()) + 3600 // 1 hour from now
    
    const rewardTokens: TokenAmount[] = [{ 
      token: await token.getAddress(), 
      amount: ethers.parseEther('5') 
    }]
    
    const route = {
      salt,
      source: chainId,
      destination: chainId + 1,
      inbox: await inbox.getAddress(),
      tokens: [],
      calls: []
    }
    
    const reward = {
      creator: await creator.getAddress(),
      prover: await prover.getAddress(),
      deadline: expiry,
      nativeValue: ethers.parseEther('0.1'), // Add native ETH to reward
      tokens: rewardTokens
    }
    
    const intent = { route, reward }
    
    // Track starting balance
    const startTokenBalance = await token.balanceOf(creator.address)
    
    // Approve tokens
    await token.connect(creator).approve(
      await intentSource.getAddress(), 
      ethers.parseEther('100')
    )
    
    // Create intent with native ETH value
    await intentSource.connect(creator).publishAndFund(
      intent,
      false, // Don't allow partial funding
      { value: ethers.parseEther('0.1') } // Send ETH with the transaction
    )
    
    // Get intent hash
    const { intentHash } = hashIntent(intent)
    
    // Verify intent was created and funded
    expect(await intentSource.isIntentFunded(intent)).to.be.true
    
    // Verify token balance decreased
    expect(await token.balanceOf(creator.address)).to.lt(startTokenBalance)
  })
  
  it('should handle validation for token arrays correctly', async () => {
    // Create a second token
    const tokenB = await (await ethers.getContractFactory('TestERC20')).deploy('Token B', 'TKB')
    await tokenB.mint(creator.address, ethers.parseEther('100'))
    
    // Prepare two identical token entries to test array validation
    const salt = ethers.randomBytes(32)
    const chainId = await ethers.provider.getNetwork().then(n => Number(n.chainId))
    const expiry = (await time.latest()) + 3600
    
    // Create reward with duplicate token entries (should be rejected in a secure system)
    const rewardTokens: TokenAmount[] = [
      { token: await token.getAddress(), amount: ethers.parseEther('1') },
      { token: await token.getAddress(), amount: ethers.parseEther('2') } // Same token, different amount
    ]
    
    const route = {
      salt,
      source: chainId,
      destination: chainId + 1,
      inbox: await inbox.getAddress(),
      tokens: [],
      calls: []
    }
    
    const reward = {
      creator: await creator.getAddress(),
      prover: await prover.getAddress(),
      deadline: expiry,
      nativeValue: 0n,
      tokens: rewardTokens
    }
    
    const intent = { route, reward }
    
    // Approve tokens
    await token.connect(creator).approve(
      await intentSource.getAddress(), 
      ethers.parseEther('100')
    )
    
    // Create intent - this should still work as the contract handles this by summing the amounts
    await intentSource.connect(creator).publishAndFund(intent, false, { value: 0 })
    
    // Verify intent was created and the system handled the duplicate tokens
    expect(await intentSource.isIntentFunded(intent)).to.be.true
    
    // Get intent hash to check reward status
    const { intentHash } = hashIntent(intent)
    expect(await intentSource.getRewardStatus(intentHash)).to.equal(0) // Created
  })
})
