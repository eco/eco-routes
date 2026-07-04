import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  TestERC20,
  Inbox,
  TestPolicy,
  MulticallRuntime,
} from '../typechain-types'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { encodeTransfer, encodeTransferPayable } from '../utils/encode'
import { BytesLike, AbiCoder, parseEther, keccak256 } from 'ethers'
import {
  hashIntent,
  encodeCalls,
  Call,
  Route,
  Reward,
  Intent,
  encodeIntent,
} from '../utils/intent'

describe('Destination Settler Test', (): void => {
  let inbox: Inbox
  let multicallRuntime: MulticallRuntime
  let erc20: TestERC20
  let owner: SignerWithAddress
  let keeper: SignerWithAddress
  let solver: SignerWithAddress
  let route: Route
  let reward: Reward
  let intent: Intent
  let intentHash: string
  let prover: TestPolicy
  let fillerData: BytesLike
  const salt = ethers.encodeBytes32String('0x987')
  let erc20Address: string
  const timeDelta = 1000
  const mintAmount = 1000
  const nativeAmount = parseEther('0.1')
  const sourceChainID = 123
  const minBatcherReward = 12345

  async function deployInboxFixture(): Promise<{
    inbox: Inbox
    multicallRuntime: MulticallRuntime
    prover: TestPolicy
    erc20: TestERC20
    owner: SignerWithAddress
    keeper: SignerWithAddress
    solver: SignerWithAddress
  }> {
    const mailbox = await (
      await ethers.getContractFactory('TestMailbox')
    ).deploy(ethers.ZeroAddress)
    const [owner, keeper, solver, dstAddr] = await ethers.getSigners()
    const portalFactory = await ethers.getContractFactory('Portal')
    const portal = await portalFactory.deploy()
    const inbox = await ethers.getContractAt('Inbox', await portal.getAddress())
    const multicallRuntime = await (
      await ethers.getContractFactory('MulticallRuntime')
    ).deploy()
    const prover = await (
      await ethers.getContractFactory('TestPolicy')
    ).deploy(await inbox.getAddress())
    // deploy ERC20 test
    const erc20Factory = await ethers.getContractFactory('TestERC20')
    const erc20 = await erc20Factory.deploy('eco', 'eco')
    await erc20.mint(solver.address, mintAmount)

    return {
      inbox,
      multicallRuntime,
      prover,
      erc20,
      owner,
      keeper,
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

    const _calldata1 = await encodeTransferPayable(keeper.address, mintAmount)
    const routeTokens = [
      { token: await erc20.getAddress(), amount: mintAmount },
    ]
    const _calls: Call[] = [
      {
        target: await erc20.getAddress(),
        data: _calldata1,
        value: _nativeAmount,
      },
    ]

    // v3 minTokens: native folds in as the address(0) leg (sorts first), then the ERC20 route tokens.
    const _route: Route = {
      salt,
      deadline: _timestamp,
      portal: await inbox.getAddress(),
      keeper: keeper.address,
      runtime: await multicallRuntime.getAddress(),
      payload: encodeCalls(_calls),
      minTokens: [
        { token: ethers.ZeroAddress, amount: _nativeAmount },
        ...routeTokens,
      ],
    }
    const _reward: Reward = {
      keeper: keeper.address,
      prover: await prover.getAddress(),
      deadline: _timestamp,
      tokens: [
        {
          token: erc20Address,
          rate: 0n,
          flat: amount,
        },
      ],
    }
    const _chainId = Number((await owner.provider.getNetwork()).chainId)
    const _intent: Intent = {
      source: _chainId,
      destination: _chainId,
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
    ;({ inbox, multicallRuntime, prover, erc20, owner, keeper, solver } =
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
      ['address'],
      [solver.address],
    )
    await expect(
      inbox
        .connect(solver)
        .fulfill(
          intent.source,
          intentHash,
          intent.route,
          hashIntent(intent).rewardHash,
          ethers.zeroPadValue(solver.address, 32),
          [nativeAmount, mintAmount],
          await prover.getAddress(),
          {
            value: nativeAmount,
          },
        ),
    ).to.be.revertedWithCustomError(inbox, 'IntentExpired')
  })
  it('successfully calls fulfill with testprover', async (): Promise<void> => {
    expect(await prover.destFulfillment(intentHash)).to.equal(ethers.ZeroHash)
    expect(await erc20.balanceOf(solver.address)).to.equal(mintAmount)

    // approves the tokens to the settler so it can process the transaction
    await erc20.connect(solver).approve(await inbox.getAddress(), mintAmount)
    fillerData = AbiCoder.defaultAbiCoder().encode(
      ['address', 'address', 'bytes'],
      [
        solver.address,
        await prover.getAddress(),
        keccak256(await prover.getAddress()), //doesnt matter, just bytes
      ],
    )
    await expect(
      inbox
        .connect(solver)
        .fulfill(
          intent.source,
          intentHash,
          intent.route,
          hashIntent(intent).rewardHash,
          ethers.zeroPadValue(solver.address, 32),
          [nativeAmount, mintAmount],
          await prover.getAddress(),
          {
            value: nativeAmount,
          },
        ),
    )
      .to.emit(inbox, 'IntentFulfilled')
      .withArgs(intentHash, ethers.zeroPadValue(solver.address, 32))

    expect(await erc20.balanceOf(keeper.address)).to.equal(mintAmount)
  })
})
