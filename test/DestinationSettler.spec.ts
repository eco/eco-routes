import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  TestERC20,
  Inbox,
  TestProver,
} from '../typechain-types'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { encodeTransfer } from '../utils/encode'
import { BytesLike, AbiCoder, parseEther } from 'ethers'
import { hashIntent, Call, Route, Reward, Intent, encodeIntent } from '../utils/intent'

describe('Destination Settler Test', (): void => {
  let inbox: Inbox
  let erc20: TestERC20
  let owner: SignerWithAddress
  let creator: SignerWithAddress
  let solver: SignerWithAddress
  let route: Route
  let reward: Reward
  let intent: Intent
  let intentHash: string
  let prover: TestProver
  let fillerData: BytesLike
  const salt = ethers.encodeBytes32String('0x987')
  let erc20Address: string
  const timeDelta = 1000
  const mintAmount = 1000
  const nativeAmount = parseEther('0.1')
  const sourceChainID = 123

  async function deployInboxFixture(): Promise<{
    inbox: Inbox
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
    const inboxFactory = await ethers.getContractFactory('Inbox')
    const inbox = await inboxFactory.deploy(owner.address, true, [])
    await inbox.connect(owner).setMailbox(await mailbox.getAddress())
    const prover = await (
      await ethers.getContractFactory('TestProver')
    ).deploy()
    // deploy ERC20 test
    const erc20Factory = await ethers.getContractFactory('TestERC20')
    const erc20 = await erc20Factory.deploy('eco', 'eco')
    await erc20.mint(solver.address, mintAmount)

    return {
      inbox,
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
    route: Route
    reward: Reward
    intent: Intent
    intentHash: string
  }> {
    erc20Address = await erc20.getAddress()
    const _timestamp = (await time.latest()) + timeDelta

    const _calldata1 = await encodeTransfer(creator.address, amount)
    const routeTokens = [
      { token: await erc20.getAddress(), amount: mintAmount },
    ]
    const _calls: Call[] = [
      {
        target: creator.address,
        data: _calldata1,
        value: _nativeAmount,
      },
    ]

    const _route: Route = {
      salt,
      source: sourceChainID,
      destination: Number((await owner.provider.getNetwork()).chainId),
      inbox: await inbox.getAddress(),
      tokens: routeTokens,
      calls: _calls,
    }
    const _reward: Reward = {
      creator: creator.address,
      prover: await prover.getAddress(),
      deadline: _timestamp,
      nativeValue: BigInt(0),
      tokens: [
        {
          token: erc20Address,
          amount: amount,
        },
      ],
    }
    const _intent: Intent = {
      route: _route,
      reward: _reward,
    }
    const {
      routeHash: _routeHash,
      rewardHash: _rewardHash,
      intentHash: _intentHash,
    } = hashIntent(_intent)
    return {
      route: _route,
      reward: _reward,
      intent: _intent,
      intentHash: _intentHash,
    }
  }

  beforeEach(async (): Promise<void> => {
    ;({ inbox, prover, erc20, owner, creator, solver } =
      await loadFixture(deployInboxFixture))
    ;({ route, reward, intent, intentHash } = await createIntentDataNative(
      mintAmount,
      nativeAmount,
      timeDelta,
    ))
  })

  it('reverts on a fill when fillDeadline has passed', async (): Promise<void> => {
    await time.increaseTo(intent.reward.deadline + 1)
    await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)
    fillerData = AbiCoder.defaultAbiCoder().encode(
        ['uint256', 'address'],
        [0, solver.address],
    )
    await expect(
         inbox
          .connect(solver)
          .fill(intentHash, encodeIntent(intent), fillerData, {
            value: nativeAmount,
          }),
      ).to.be.revertedWithCustomError(inbox, 'FillDeadlinePassed')
  })
  it('successfully calls storage prover fulfill', async (): Promise<void> => {
    expect(await inbox.fulfilled(intentHash)).to.equal(ethers.ZeroAddress)
    expect(await erc20.balanceOf(solver.address)).to.equal(mintAmount)

    // approves the tokens to the settler so it can process the transaction
    await erc20
      .connect(solver)
      .approve(await inbox.getAddress(), mintAmount)
    fillerData = AbiCoder.defaultAbiCoder().encode(
      ['uint256', 'address'],
      [0, solver.address],
    )
    expect(
      await inbox
        .connect(solver)
        .fill(intentHash, encodeIntent(intent), fillerData, {
          value: nativeAmount,
        }),
    )
      .to.emit(inbox, 'ToBeProven')
      .withArgs(intentHash, route.source, solver.address)
  })

  it('successfully calls hyper instant fulfill', async (): Promise<void> => {
    expect(await inbox.fulfilled(intentHash)).to.equal(ethers.ZeroAddress)
    expect(await erc20.balanceOf(solver.address)).to.equal(mintAmount)

    // transfer the tokens to the settler so it can process the transaction
    await erc20
      .connect(solver)
      .approve(await inbox.getAddress(), mintAmount)
    fillerData = AbiCoder.defaultAbiCoder().encode(
      ['uint256', 'address', 'address', 'bytes'],
      [1, solver.address, ethers.ZeroAddress, '0x'],
    )
    expect(
      await inbox
        .connect(solver)
        .fill(intentHash, encodeIntent(intent), fillerData, {
          value: nativeAmount + BigInt(120000), // add some extra to pay for hyperlane gas
        }),
    )
      .to.emit(inbox, 'HyperInstantFulfillment')
      .withArgs(intentHash, route.source, solver.address)
  })
})
