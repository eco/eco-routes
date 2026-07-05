import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  TestERC20,
  IntentSource,
  Portal,
  TestPolicy,
  Inbox,
  MulticallRuntime,
} from '../typechain-types'
import { hashIntent, encodeCalls, RewardToken } from '../utils/intent'

/**
 * This test suite focuses on testing the protocol's resilience against token security issues
 */
describe('Token Security Tests', () => {
  let intentSource: IntentSource
  let prover: TestPolicy
  let inbox: Inbox
  let multicallRuntime: MulticallRuntime
  let token: TestERC20
  let keeper: SignerWithAddress
  let claimant: SignerWithAddress

  async function deployContractsFixture() {
    const [keeper, claimant] = await ethers.getSigners()

    // Deploy Portal (which includes IntentSource and Inbox)
    const portalProxy = await (
      await ethers.getContractFactory('PortalProxy')
    ).deploy(keeper.address)
    const accountImpl = await (
      await ethers.getContractFactory('Account')
    ).deploy(await portalProxy.getAddress())
    const portalImpl = await (
      await ethers.getContractFactory('Portal')
    ).deploy(await accountImpl.getAddress())
    await portalProxy.registerVersion(1, await portalImpl.getAddress())
    const portal = await ethers.getContractAt(
      'Portal',
      await portalProxy.getAddress(),
    )
    // Use the IIntentSource interface with the Portal implementation
    const intentSource = await ethers.getContractAt(
      'IIntentSource',
      await portal.getAddress(),
    )

    // Get Inbox interface from Portal
    inbox = await ethers.getContractAt('Inbox', await portal.getAddress())

    // Deploy test prover
    prover = await (
      await ethers.getContractFactory('TestPolicy')
    ).deploy(await portal.getAddress())

    // Deploy the default v3 route runtime
    const multicallRuntime = await (
      await ethers.getContractFactory('MulticallRuntime')
    ).deploy()

    // Deploy test token
    const tokenFactory = await ethers.getContractFactory('TestERC20')
    const token = await tokenFactory.deploy('Test Token', 'TEST')

    // Mint tokens to keeper
    await token.mint(keeper.address, ethers.parseEther('100'))

    return {
      intentSource,
      prover,
      inbox,
      multicallRuntime,
      token,
      keeper,
      claimant,
    }
  }

  beforeEach(async () => {
    ;({
      intentSource,
      prover,
      inbox,
      multicallRuntime,
      token,
      keeper,
      claimant,
    } = await loadFixture(deployContractsFixture))
  })

  it('should handle token transfers correctly in intent creation', async () => {
    // Setup intent data
    const salt = ethers.randomBytes(32)
    const chainId = await ethers.provider
      .getNetwork()
      .then((n) => Number(n.chainId))
    const routeTokens: any[] = []
    const calls = []
    const expiry = (await time.latest()) + 3600 // 1 hour from now

    const rewardTokens: RewardToken[] = [
      {
        token: await token.getAddress(),
        rate: 0n,
        flat: ethers.parseEther('1'),
      },
    ]

    // Create route and reward
    const route = {
      salt,
      deadline: expiry,
      portal: await inbox.getAddress(),
      keeper: await keeper.getAddress(),
      minTokens: routeTokens,
      runtime: await multicallRuntime.getAddress(),
      payload: encodeCalls(calls),
    }

    const reward = {
      keeper: await keeper.getAddress(),
      prover: await prover.getAddress(),
      deadline: expiry,
      tokens: rewardTokens,
      hooks: '0x',
    }

    const intent = {
      protocolVersion: 1,
      source: chainId,
      destination: chainId + 1,
      route,
      reward,
    }

    // Approve tokens for spending
    await token
      .connect(keeper)
      .approve(await intentSource.getAddress(), ethers.parseEther('100'))

    // Create intent with tokens
    await intentSource
      .connect(keeper)
      .publishAndFund(intent, false, { value: 0 })

    // Verify intent was created and funded
    const { intentHash } = hashIntent(intent)
    expect(await intentSource.isIntentFunded(intent)).to.be.true

    // Verify reward status is correct - RewardStatus.Funded = 1
    expect(await intentSource.getRewardStatus(intentHash)).to.equal(1)
  })

  it('should handle multiple token rewards correctly', async () => {
    // Deploy a second token
    const tokenB = await (
      await ethers.getContractFactory('TestERC20')
    ).deploy('Token B', 'TKB')
    await tokenB.mint(keeper.address, ethers.parseEther('100'))

    // Setup intent data with multiple reward tokens
    const salt = ethers.randomBytes(32)
    const chainId = await ethers.provider
      .getNetwork()
      .then((n) => Number(n.chainId))
    const expiry = (await time.latest()) + 3600 // 1 hour from now

    const rewardTokens: RewardToken[] = [
      {
        token: await token.getAddress(),
        rate: 0n,
        flat: ethers.parseEther('2'),
      },
      {
        token: await tokenB.getAddress(),
        rate: 0n,
        flat: ethers.parseEther('3'),
      },
    ]

    const route = {
      salt,
      deadline: expiry,
      portal: await inbox.getAddress(),
      keeper: await keeper.getAddress(),
      minTokens: [],
      runtime: await multicallRuntime.getAddress(),
      payload: encodeCalls([]),
    }

    const reward = {
      keeper: await keeper.getAddress(),
      prover: await prover.getAddress(),
      deadline: expiry,
      tokens: rewardTokens,
      hooks: '0x',
    }

    const intent = {
      protocolVersion: 1,
      source: chainId,
      destination: chainId + 1,
      route,
      reward,
    }

    // Approve both tokens for spending
    await token
      .connect(keeper)
      .approve(await intentSource.getAddress(), ethers.parseEther('100'))

    await tokenB
      .connect(keeper)
      .approve(await intentSource.getAddress(), ethers.parseEther('100'))

    // Create intent with multiple tokens
    await intentSource
      .connect(keeper)
      .publishAndFund(intent, false, { value: 0 })

    // Verify intent was created and funded
    expect(await intentSource.isIntentFunded(intent)).to.be.true
  })

  it('should handle intent creation with combined native and token rewards', async () => {
    // Setup intent data with both native value and token rewards
    const salt = ethers.randomBytes(32)
    const chainId = await ethers.provider
      .getNetwork()
      .then((n) => Number(n.chainId))
    const expiry = (await time.latest()) + 3600 // 1 hour from now

    const rewardTokens: RewardToken[] = [
      {
        token: await token.getAddress(),
        rate: 0n,
        flat: ethers.parseEther('5'),
      },
      // Native ETH reward folds in as a leg with token == address(0)
      {
        token: ethers.ZeroAddress,
        rate: 0n,
        flat: ethers.parseEther('0.1'),
      },
    ]

    const route = {
      salt,
      deadline: expiry,
      portal: await inbox.getAddress(),
      keeper: await keeper.getAddress(),
      minTokens: [],
      runtime: await multicallRuntime.getAddress(),
      payload: encodeCalls([]),
    }

    const reward = {
      keeper: await keeper.getAddress(),
      prover: await prover.getAddress(),
      deadline: expiry,
      tokens: rewardTokens,
      hooks: '0x',
    }

    const intent = {
      protocolVersion: 1,
      source: chainId,
      destination: chainId + 1,
      route,
      reward,
    }

    // Track starting balance
    const startTokenBalance = await token.balanceOf(keeper.address)

    // Approve tokens
    await token
      .connect(keeper)
      .approve(await intentSource.getAddress(), ethers.parseEther('100'))

    // Create intent with native ETH value
    await intentSource.connect(keeper).publishAndFund(
      intent,
      false, // Don't allow partial funding
      { value: ethers.parseEther('0.1') }, // Send ETH with the transaction
    )

    // Get intent hash
    const { intentHash } = hashIntent(intent)

    // Verify intent was created and funded
    expect(await intentSource.isIntentFunded(intent)).to.be.true

    // Verify token balance decreased
    expect(await token.balanceOf(keeper.address)).to.lt(startTokenBalance)
  })

  it('should handle validation for token arrays correctly', async () => {
    // Create a second token
    const tokenB = await (
      await ethers.getContractFactory('TestERC20')
    ).deploy('Token B', 'TKB')
    await tokenB.mint(keeper.address, ethers.parseEther('100'))

    // Prepare two identical token entries to test array validation
    const salt = ethers.randomBytes(32)
    const chainId = await ethers.provider
      .getNetwork()
      .then((n) => Number(n.chainId))
    const expiry = (await time.latest()) + 3600

    // Create reward with duplicate token entries. In v3 the source enforces UNIQUE reward legs
    // (requireUniqueRewardTokens), so a duplicate token is rejected rather than summed.
    const rewardTokens: RewardToken[] = [
      {
        token: await token.getAddress(),
        rate: 0n,
        flat: ethers.parseEther('1'),
      },
      {
        token: await token.getAddress(),
        rate: 0n,
        flat: ethers.parseEther('2'),
      }, // Same token
    ]

    const route = {
      salt,
      deadline: expiry,
      portal: await inbox.getAddress(),
      keeper: await keeper.getAddress(),
      minTokens: [],
      runtime: await multicallRuntime.getAddress(),
      payload: encodeCalls([]),
    }

    const reward = {
      keeper: await keeper.getAddress(),
      prover: await prover.getAddress(),
      deadline: expiry,
      tokens: rewardTokens,
      hooks: '0x',
    }

    const intent = {
      protocolVersion: 1,
      source: chainId,
      destination: chainId + 1,
      route,
      reward,
    }

    // Approve tokens
    await token
      .connect(keeper)
      .approve(await intentSource.getAddress(), ethers.parseEther('100'))

    // v3 rejects duplicate reward legs at publish time (RewardTokensNotUnique)
    const portal = await ethers.getContractAt(
      'Portal',
      await intentSource.getAddress(),
    )
    await expect(
      intentSource.connect(keeper).publishAndFund(intent, false, { value: 0 }),
    ).to.be.revertedWithCustomError(portal, 'RewardTokensNotUnique')

    // Verify the intent was NOT funded
    expect(await intentSource.isIntentFunded(intent)).to.be.false
  })
})
