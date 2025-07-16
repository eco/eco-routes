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
} from '../utils/intent'
import { addressToBytes32, bytes32ToAddress } from '../utils/typeCasts'
import {
  UniversalIntent,
  UniversalRoute,
  UniversalReward,
  hashUniversalIntent,
  convertIntentToUniversal,
  MAX_UINT64,
} from '../utils/universalIntent'
import {
  UniversalOnchainCrosschainOrderData,
  encodeUniversalOnchainCrosschainOrderData,
  UniversalRoute as EcoUniversalRoute,
} from '../utils/universalEcoERC7683'
import { TypeCasts } from '../utils/typeCasts'

describe('Destination Settler Test', (): void => {
  let inbox: Inbox
  let destinationSettler: Eco7683DestinationSettler
  let erc20: TestERC20
  let owner: SignerWithAddress
  let creator: SignerWithAddress
  let solver: SignerWithAddress
  let universalIntent: UniversalIntent
  let intentHash: string
  let prover: TestProver
  let fillerData: BytesLike
  let orderData: UniversalOnchainCrosschainOrderData
  const salt = ethers.encodeBytes32String('0x987')
  let erc20Address: string
  const timeDelta = 1000
  const mintAmount = 1000
  const nativeAmount = parseEther('0.1')
  const sourceChainID = 123
  const minBatcherReward = 12345

  async function deployInboxFixture(): Promise<{
    inbox: Inbox
    destinationSettler: Eco7683DestinationSettler
    prover: TestProver
    erc20: TestERC20
    owner: SignerWithAddress
    creator: SignerWithAddress
    solver: SignerWithAddress
  }> {
    const mailbox = await (
      await ethers.getContractFactory('TestMailbox')
    ).deploy(ethers.ZeroAddress)
    const [owner, creator, solver, dstAddr] = await ethers.getSigners()
    const portalFactory = await ethers.getContractFactory('Portal')
    const portal = await portalFactory.deploy()
    const inbox = await ethers.getContractAt('Inbox', await portal.getAddress())
    const prover = await (
      await ethers.getContractFactory('TestProver')
    ).deploy(await portal.getAddress())

    // Deploy the destination settler that handles token transfers
    const destinationSettlerFactory = await ethers.getContractFactory(
      'TestDestinationSettlerComplete',
    )
    const destinationSettler = await destinationSettlerFactory.deploy(
      await inbox.getAddress(),
    )
    // deploy ERC20 test
    const erc20Factory = await ethers.getContractFactory('TestERC20')
    const erc20 = await erc20Factory.deploy('eco', 'eco')
    await erc20.mint(solver.address, mintAmount)

    return {
      inbox,
      destinationSettler,
      prover,
      erc20,
      owner,
      creator,
      solver,
    }
  }
  async function createIntentDataNative(
    amount: number,
    _nativeAmount: bigint,
    timeDelta: number,
  ): Promise<{
    universalIntent: UniversalIntent
    intentHash: string
    orderData: UniversalOnchainCrosschainOrderData
  }> {
    erc20Address = await erc20.getAddress()
    const _timestamp = (await time.latest()) + timeDelta

    const _calldata1 = await encodeTransferPayable(creator.address, mintAmount)
    const destination = Number((await owner.provider.getNetwork()).chainId)

    // IMPORTANT: The DestinationSettler contract uses type(uint64).max for deadline
    // since it's not included in OnchainCrosschainOrderData
    // We need to use the exact same value the contract uses
    const contractDeadline = MAX_UINT64

    // Create the intent with address-based types first
    const _intent: Intent = {
      destination: destination,
      route: {
        salt,
        deadline: contractDeadline, // Use the deadline the contract will use
        portal: await inbox.getAddress(),
        tokens: [{ token: await erc20.getAddress(), amount: mintAmount }],
        calls: [
          {
            target: await erc20.getAddress(),
            data: _calldata1,
            value: 0, // ERC20 transfers don't need ETH
          },
        ],
      },
      reward: {
        creator: creator.address,
        prover: await prover.getAddress(),
        deadline: contractDeadline, // Use the deadline the contract will use
        nativeValue: BigInt(0),
        tokens: [
          {
            token: erc20Address,
            amount: amount,
          },
        ],
      },
    }

    // Convert to UniversalIntent
    const universalIntent = convertIntentToUniversal(_intent)
    const { intentHash: _intentHash } = hashUniversalIntent(universalIntent)

    // Create the UniversalOnchainCrosschainOrderData for the fill function
    const orderData: UniversalOnchainCrosschainOrderData = {
      destination: destination,
      route: {
        salt: universalIntent.route.salt,
        deadline: universalIntent.route.deadline,
        portal: universalIntent.route.portal,
        tokens: universalIntent.route.tokens,
        calls: universalIntent.route.calls,
      } as EcoUniversalRoute,
      creator: universalIntent.reward.creator,
      prover: universalIntent.reward.prover,
      nativeValue: universalIntent.reward.nativeValue,
      rewardTokens: universalIntent.reward.tokens,
    }

    return {
      universalIntent,
      intentHash: _intentHash,
      orderData,
    }
  }

  beforeEach(async (): Promise<void> => {
    ;({ inbox, destinationSettler, prover, erc20, owner, creator, solver } =
      await loadFixture(deployInboxFixture))
    ;({ universalIntent, intentHash, orderData } = await createIntentDataNative(
      mintAmount,
      nativeAmount,
      timeDelta,
    ))
  })

  it('reverts on a fill when fillDeadline has passed', async (): Promise<void> => {
    // Create an intent with an expired deadline
    const currentTime = await time.latest()
    const expiredDeadline = currentTime - 100 // Set deadline in the past

    // Create a custom intent with expired deadline
    const erc20Address = await erc20.getAddress()
    const destination = Number((await owner.provider.getNetwork()).chainId)
    const _calldata1 = await encodeTransferPayable(creator.address, mintAmount)

    const expiredIntent: Intent = {
      destination: destination,
      route: {
        salt,
        deadline: expiredDeadline, // Use expired deadline
        portal: await inbox.getAddress(),
        tokens: [{ token: await erc20.getAddress(), amount: mintAmount }],
        calls: [
          {
            target: await erc20.getAddress(),
            data: _calldata1,
            value: 0, // ERC20 transfers don't need ETH
          },
        ],
      },
      reward: {
        creator: creator.address,
        prover: await prover.getAddress(),
        deadline: currentTime + timeDelta,
        nativeValue: BigInt(0),
        tokens: [
          {
            token: await erc20.getAddress(),
            amount: mintAmount,
          },
        ],
      },
    }

    const expiredUniversalIntent = convertIntentToUniversal(expiredIntent)
    const { intentHash: expiredIntentHash } = hashUniversalIntent(
      expiredUniversalIntent,
    )

    // Create the UniversalOnchainCrosschainOrderData for the fill function
    const expiredOrderData: UniversalOnchainCrosschainOrderData = {
      destination: destination,
      route: {
        salt: expiredUniversalIntent.route.salt,
        deadline: expiredUniversalIntent.route.deadline,
        portal: expiredUniversalIntent.route.portal,
        tokens: expiredUniversalIntent.route
          .tokens as EcoUniversalRoute['tokens'],
        calls: expiredUniversalIntent.route.calls as EcoUniversalRoute['calls'],
      },
      reward: expiredUniversalIntent.reward,
    }

    // Approve tokens for the solver
    await erc20
      .connect(solver)
      .approve(await destinationSettler.getAddress(), mintAmount)

    // Encode filler data with proper prover information
    fillerData = AbiCoder.defaultAbiCoder().encode(
      ['address', 'uint64', 'bytes32', 'bytes'],
      [
        await prover.getAddress(),
        2, // source
        TypeCasts.addressToBytes32(creator.address), // claimant
        AbiCoder.defaultAbiCoder().encode(['uint256'], [0]), // proverData
      ],
    )

    // Expect the transaction to revert when deadline has passed
    // The DestinationSettler.fill() should check route.deadline and revert with FillDeadlinePassed
    await expect(
      destinationSettler
        .connect(solver)
        .fill(
          expiredIntentHash,
          await encodeUniversalOnchainCrosschainOrderData(expiredOrderData),
          fillerData,
          {
            value: 0, // No ETH needed for ERC20 transfers
          },
        ),
    ).to.be.reverted
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

    // Convert UniversalRoute to regular Route
    const route: Route = {
      salt: orderData.route.salt,
      deadline: orderData.route.deadline,
      portal: bytes32ToAddress(orderData.route.portal),
      tokens: orderData.route.tokens.map((t) => ({
        token: bytes32ToAddress(t.token),
        amount: t.amount,
      })),
      calls: orderData.route.calls.map((c) => ({
        target: bytes32ToAddress(c.target),
        data: c.data,
        value: c.value,
      })),
    }

    // Create reward from orderData for hash calculation
    const reward: Reward = {
      deadline: orderData.reward?.deadline || universalIntent.reward.deadline,
      creator: bytes32ToAddress(
        orderData.creator || universalIntent.reward.creator,
      ),
      prover: bytes32ToAddress(
        orderData.prover || universalIntent.reward.prover,
      ),
      nativeValue: orderData.nativeValue || universalIntent.reward.nativeValue,
      tokens: (orderData.rewardTokens || universalIntent.reward.tokens).map(
        (t) => ({
          token: bytes32ToAddress(t.token),
          amount: t.amount,
        }),
      ),
    }
    const rewardHash = keccak256(encodeReward(reward))

    // Encode originData as (bytes, bytes32) - first encode the route, then pack it with rewardHash
    const encodedRoute = AbiCoder.defaultAbiCoder().encode(
      [
        {
          type: 'tuple',
          components: [
            { name: 'salt', type: 'bytes32' },
            { name: 'deadline', type: 'uint64' },
            { name: 'portal', type: 'address' },
            {
              name: 'tokens',
              type: 'tuple[]',
              components: [
                { name: 'token', type: 'address' },
                { name: 'amount', type: 'uint256' },
              ],
            },
            {
              name: 'calls',
              type: 'tuple[]',
              components: [
                { name: 'target', type: 'address' },
                { name: 'data', type: 'bytes' },
                { name: 'value', type: 'uint256' },
              ],
            },
          ],
        },
      ],
      [route],
    )

    const originData = AbiCoder.defaultAbiCoder().encode(
      ['bytes', 'bytes32'],
      [encodedRoute, rewardHash],
    )

    await expect(
      destinationSettler
        .connect(solver)
        .fill(intentHash, originData, fillerData, {
          value: 0, // No ETH needed for ERC20 transfers
        }),
    )
      .to.emit(destinationSettler, 'OrderFilled')
      .withArgs(intentHash, solver.address)
      .and.to.emit(inbox, 'IntentFulfilled')
      .withArgs(intentHash, addressToBytes32(solver.address))

    expect(await erc20.balanceOf(creator.address)).to.equal(mintAmount)
  })
})
