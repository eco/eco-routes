import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  TestERC20,
  Inbox,
  Portal,
  TestProver,
  Eco7683DestinationSettler,
} from '../typechain-types'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { encodeTransfer, encodeTransferPayable } from '../utils/encode'
import { BytesLike, AbiCoder, parseEther, MaxUint256, keccak256 } from 'ethers'
import {
  hashIntent,
  Call,
  Reward,
  Intent,
  encodeIntent,
  Route,
  encodeReward,
  encodeRoute,
} from '../utils/intent'
import {
  addressToBytes32,
  bytes32ToAddress,
  TypeCasts,
} from '../utils/typeCasts'

describe('Destination Settler Test', (): void => {
  let inbox: Inbox
  let destinationSettler: Eco7683DestinationSettler
  let erc20: TestERC20
  let owner: SignerWithAddress
  let creator: SignerWithAddress
  let solver: SignerWithAddress
  let intent: Intent
  let intentHash: string
  let reward: Reward
  let route: Route
  let sampleCall: Call
  let originData: BytesLike
  let fillerData: BytesLike
  let prover: TestProver
  const sourceChainID = 1
  const claimantSalt = ethers.id('test.salt')
  const mintAmount = 100
  const rewardAmount = 0

  async function deployPortal(): Promise<{
    inbox: Inbox
    destinationSettler: Eco7683DestinationSettler
    erc20: TestERC20
    prover: TestProver
    owner: SignerWithAddress
    creator: SignerWithAddress
    solver: SignerWithAddress
  }> {
    const [owner, creator, solver] = await ethers.getSigners()

    // Deploy a test ERC20 token
    const TestERC20 = await ethers.getContractFactory('TestERC20')
    const erc20 = await TestERC20.deploy('TestToken', 'TEST')

    // Deploy the Portal (which is also the Inbox)
    const Portal = await ethers.getContractFactory('Portal')
    const portal = await Portal.deploy()
    const inbox = await ethers.getContractAt('Inbox', await portal.getAddress())

    // Deploy the TestProver
    const TestProver = await ethers.getContractFactory('TestProver')
    const prover = await TestProver.deploy(await inbox.getAddress())

    // Deploy the TestDestinationSettlerComplete
    const DestinationSettler = await ethers.getContractFactory(
      'TestDestinationSettlerComplete',
    )
    const destinationSettler = await DestinationSettler.deploy(
      await inbox.getAddress(),
    )

    // Mint some tokens to the solver
    await erc20.mint(solver.address, mintAmount)

    return {
      inbox,
      destinationSettler,
      erc20,
      prover,
      owner,
      creator,
      solver,
    }
  }

  beforeEach(async (): Promise<void> => {
    ;({ inbox, destinationSettler, erc20, prover, owner, creator, solver } =
      await loadFixture(deployPortal))

    // Create a sample intent
    sampleCall = {
      target: await erc20.getAddress(),
      data: await encodeTransfer(creator.address, mintAmount),
      value: 0,
    }

    route = {
      salt: claimantSalt,
      deadline: (await time.latest()) + 1000,
      portal: await inbox.getAddress(),
      tokens: [{ token: await erc20.getAddress(), amount: mintAmount }],
      calls: [sampleCall],
    }

    reward = {
      deadline: (await time.latest()) + 1000,
      creator: creator.address,
      prover: await prover.getAddress(),
      nativeValue: rewardAmount,
      tokens: [],
    }

    intent = {
      destination: 31337, // Use hardhat's chain ID
      route,
      reward,
    }

    // Calculate the intent hash using regular intent
    const hashes = hashIntent(intent)
    intentHash = hashes.intentHash

    // Encode the route using the utility function
    const encodedRoute = encodeRoute(route)

    // Calculate reward hash
    const rewardHash = keccak256(encodeReward(reward))

    // Create originData for the settler (encoded route and reward hash)
    originData = AbiCoder.defaultAbiCoder().encode(
      ['bytes', 'bytes32'],
      [encodedRoute, rewardHash],
    )

    // Create fillerData
    fillerData = AbiCoder.defaultAbiCoder().encode(
      ['address', 'uint64', 'bytes32', 'bytes'],
      [
        await prover.getAddress(),
        sourceChainID,
        addressToBytes32(solver.address),
        '0x',
      ],
    )
  })

  it('should expire intents that are passed deadline', async (): Promise<void> => {
    const latestTime = await time.latest()
    const _expiredIntent = {
      destination: 31337,
      route: {
        salt: claimantSalt,
        deadline: latestTime - 1000,
        portal: await inbox.getAddress(),
        tokens: [{ token: await erc20.getAddress(), amount: mintAmount }],
        calls: [sampleCall],
      },
      reward: {
        deadline: latestTime - 1000,
        creator: creator.address,
        prover: await prover.getAddress(),
        nativeValue: rewardAmount,
        tokens: [],
      },
    }

    const expiredIntent = _expiredIntent as Intent
    const hashes = hashIntent(expiredIntent)
    const expiredIntentHash = hashes.intentHash

    // Removed - now encoding inline

    // Encode expired intent data
    const expiredEncodedRoute = encodeRoute(expiredIntent.route)

    const expiredRewardHash = keccak256(encodeReward(expiredIntent.reward))
    const expiredOriginData = AbiCoder.defaultAbiCoder().encode(
      ['bytes', 'bytes32'],
      [expiredEncodedRoute, expiredRewardHash],
    )

    await expect(
      destinationSettler
        .connect(solver)
        .fill(expiredIntentHash, expiredOriginData, fillerData),
    ).to.revertedWithCustomError(destinationSettler, 'FillDeadlinePassed')
  })

  it('successfully calls fulfill with testprover', async (): Promise<void> => {
    expect(await inbox.fulfilled(intentHash)).to.equal(ethers.ZeroHash)
    expect(await erc20.balanceOf(solver.address)).to.equal(mintAmount)

    // The solver approves the destination settler to transfer tokens
    // The settler will handle transferring tokens and approving the inbox
    await erc20
      .connect(solver)
      .approve(await destinationSettler.getAddress(), mintAmount)

    // The fillerData should encode: (prover, source, claimant, proverData)
    fillerData = AbiCoder.defaultAbiCoder().encode(
      ['address', 'uint64', 'bytes32', 'bytes'],
      [
        await prover.getAddress(),
        sourceChainID,
        addressToBytes32(solver.address),
        '0x',
      ],
    )

    // Removed - no longer needed

    // Call the settler
    await destinationSettler
      .connect(solver)
      .fill(intentHash, originData, fillerData)

    // Verify the fulfill was successful
    expect(await inbox.fulfilled(intentHash)).to.equal(
      addressToBytes32(solver.address),
    )
    expect(await erc20.balanceOf(solver.address)).to.equal(0)
    expect(await erc20.balanceOf(creator.address)).to.equal(mintAmount)

    // Verify the prover was called with correct arguments
    const args = await prover.args()
    expect(args.sender).to.equal(await destinationSettler.getAddress())
    expect(args.sourceChainId).to.equal(sourceChainID)

    const argIntentHashes = await prover.argIntentHashes(0)
    expect(argIntentHashes).to.equal(intentHash)

    const argClaimants = await prover.argClaimants(0)
    expect(argClaimants).to.equal(addressToBytes32(solver.address))
  })

  it('should revert if tokens not approved', async (): Promise<void> => {
    await expect(
      destinationSettler
        .connect(solver)
        .fill(intentHash, originData, fillerData),
    ).to.be.revertedWithCustomError(erc20, 'ERC20InsufficientAllowance')
  })

  it('should fulfill an intent when given native value', async (): Promise<void> => {
    // Create a native value intent
    const nativeValueRoute: Route = {
      salt: claimantSalt,
      deadline: (await time.latest()) + 1000,
      portal: await inbox.getAddress(),
      tokens: [],
      calls: [
        {
          target: creator.address,
          data: '0x',
          value: parseEther('1'),
        },
      ],
    }

    const nativeValueReward: Reward = {
      deadline: (await time.latest()) + 1000,
      creator: creator.address,
      prover: await prover.getAddress(),
      nativeValue: 0,
      tokens: [],
    }

    const nativeValueIntent: Intent = {
      destination: 31337,
      route: nativeValueRoute,
      reward: nativeValueReward,
    }

    const nativeValueHashes = hashIntent(nativeValueIntent)
    const nativeValueIntentHash = nativeValueHashes.intentHash

    // Encode native value intent data
    const nativeValueEncodedRoute = encodeRoute(nativeValueRoute)

    const nativeValueRewardHash = keccak256(encodeReward(nativeValueReward))
    const nativeValueOriginData = AbiCoder.defaultAbiCoder().encode(
      ['bytes', 'bytes32'],
      [nativeValueEncodedRoute, nativeValueRewardHash],
    )

    const creatorBalanceBefore = await ethers.provider.getBalance(
      creator.address,
    )

    // Call fill with native value
    await destinationSettler
      .connect(solver)
      .fill(nativeValueIntentHash, nativeValueOriginData, fillerData, {
        value: parseEther('1'),
      })

    // Verify the native value was transferred
    const creatorBalanceAfter = await ethers.provider.getBalance(
      creator.address,
    )
    expect(creatorBalanceAfter - creatorBalanceBefore).to.equal(parseEther('1'))

    // Verify the fulfill was successful
    expect(await inbox.fulfilled(nativeValueIntentHash)).to.equal(
      addressToBytes32(solver.address),
    )
  })

  it('should revert if insufficient native value provided', async (): Promise<void> => {
    const nativeValueRoute: Route = {
      salt: claimantSalt,
      deadline: (await time.latest()) + 1000,
      portal: await inbox.getAddress(),
      tokens: [],
      calls: [
        {
          target: creator.address,
          data: '0x',
          value: parseEther('1'),
        },
      ],
    }

    const nativeValueReward: Reward = {
      deadline: (await time.latest()) + 1000,
      creator: creator.address,
      prover: await prover.getAddress(),
      nativeValue: 0,
      tokens: [],
    }

    const nativeValueIntent: Intent = {
      destination: 31337,
      route: nativeValueRoute,
      reward: nativeValueReward,
    }

    const nativeValueHashes = hashIntent(nativeValueIntent)
    const nativeValueIntentHash = nativeValueHashes.intentHash

    // Encode native value intent data
    const nativeValueEncodedRoute = encodeRoute(nativeValueRoute)
    const nativeValueRewardHash = keccak256(encodeReward(nativeValueReward))
    const nativeValueOriginData = AbiCoder.defaultAbiCoder().encode(
      ['bytes', 'bytes32'],
      [nativeValueEncodedRoute, nativeValueRewardHash],
    )

    await expect(
      destinationSettler.connect(solver).fill(
        nativeValueIntentHash,
        nativeValueOriginData,
        fillerData,
        { value: parseEther('0.5') }, // Insufficient value
      ),
    ).to.be.revertedWithCustomError(inbox, 'InsufficientFunds')
  })

  it('should work with multiple tokens and native value', async (): Promise<void> => {
    // Deploy a second token
    const TestERC20_2 = await ethers.getContractFactory('TestERC20')
    const erc20_2 = await TestERC20_2.deploy('TestToken2', 'TEST2')
    const mintAmount2 = 200

    // Mint tokens to solver
    await erc20_2.mint(solver.address, mintAmount2)

    // Create a multi-token intent with native value
    const multiRoute: Route = {
      salt: claimantSalt,
      deadline: (await time.latest()) + 1000,
      portal: await inbox.getAddress(),
      tokens: [
        { token: await erc20.getAddress(), amount: mintAmount },
        { token: await erc20_2.getAddress(), amount: mintAmount2 },
      ],
      calls: [
        {
          target: await erc20.getAddress(),
          data: await encodeTransfer(creator.address, mintAmount),
          value: 0,
        },
        {
          target: await erc20_2.getAddress(),
          data: await encodeTransfer(creator.address, mintAmount2),
          value: 0,
        },
        {
          target: creator.address,
          data: '0x',
          value: parseEther('0.5'),
        },
      ],
    }

    const multiIntent: Intent = {
      destination: 31337,
      route: multiRoute,
      reward,
    }

    const multiHashes = hashIntent(multiIntent)
    const multiIntentHash = multiHashes.intentHash

    // Encode multi-token intent data
    const multiEncodedRoute = encodeRoute(multiRoute)

    const multiRewardHash = keccak256(encodeReward(reward))
    const multiOriginData = AbiCoder.defaultAbiCoder().encode(
      ['bytes', 'bytes32'],
      [multiEncodedRoute, multiRewardHash],
    )

    // Approve tokens
    await erc20
      .connect(solver)
      .approve(await destinationSettler.getAddress(), mintAmount)
    await erc20_2
      .connect(solver)
      .approve(await destinationSettler.getAddress(), mintAmount2)

    const creatorNativeBalanceBefore = await ethers.provider.getBalance(
      creator.address,
    )

    // Call fill
    await destinationSettler
      .connect(solver)
      .fill(multiIntentHash, multiOriginData, fillerData, {
        value: parseEther('0.5'),
      })

    // Verify all transfers
    expect(await erc20.balanceOf(creator.address)).to.equal(mintAmount)
    expect(await erc20_2.balanceOf(creator.address)).to.equal(mintAmount2)
    const creatorNativeBalanceAfter = await ethers.provider.getBalance(
      creator.address,
    )
    expect(creatorNativeBalanceAfter - creatorNativeBalanceBefore).to.equal(
      parseEther('0.5'),
    )
    expect(await inbox.fulfilled(multiIntentHash)).to.equal(
      addressToBytes32(solver.address),
    )
  })
})
