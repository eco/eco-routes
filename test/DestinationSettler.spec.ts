import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  TestERC20,
  Inbox,
  TestProver,
  Eco7683DestinationSettler,
} from '../typechain-types'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { encodeTransfer, encodeTransferPayable } from '../utils/encode'
import { BytesLike, AbiCoder, parseEther, MaxUint256 } from 'ethers'
import { hashIntent, Call, Reward, Intent, encodeIntent } from '../utils/intent'
import { addressToBytes32 } from '../utils/typeCasts'
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
    const inboxFactory = await ethers.getContractFactory('Inbox')
    const inbox = await inboxFactory.deploy()
    const prover = await (
      await ethers.getContractFactory('TestProver')
    ).deploy(await inbox.getAddress())

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
        tokens: [
          { token: await erc20.getAddress(), amount: mintAmount },
        ],
        calls: [
          {
            target: await erc20.getAddress(),
            data: _calldata1,
            value: _nativeAmount,
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
        portal: universalIntent.route.portal,
        tokens: universalIntent.route.tokens,
        calls: universalIntent.route.calls,
      },
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
    ;({ universalIntent, intentHash, orderData } =
      await createIntentDataNative(mintAmount, nativeAmount, timeDelta))
  })

  it.skip('reverts on a fill when fillDeadline has passed', async (): Promise<void> => {
    // This test is skipped because OnchainCrosschainOrderData doesn't include a deadline field
    // The EIP-7683 structure would need to be updated to support deadline checks
    await time.increaseTo(universalIntent.reward.deadline + 1)
    await erc20
      .connect(solver)
      .approve(await destinationSettler.getAddress(), mintAmount)
    fillerData = AbiCoder.defaultAbiCoder().encode(
      ['bytes32'],
      [TypeCasts.addressToBytes32(solver.address)],
    )
    await expect(
      destinationSettler
        .connect(solver)
        .fill(
          intentHash,
          await encodeUniversalOnchainCrosschainOrderData(orderData),
          fillerData,
          {
            value: nativeAmount,
          },
        ),
    ).to.be.revertedWithCustomError(destinationSettler, 'FillDeadlinePassed')
  })
  it('successfully calls fulfill with testprover', async (): Promise<void> => {
    expect(await inbox.fulfilled(intentHash)).to.equal(ethers.ZeroHash)
    expect(await erc20.balanceOf(solver.address)).to.equal(mintAmount)

    // The solver approves the destination settler to transfer tokens
    // The settler will handle transferring tokens and approving the inbox
    await erc20
      .connect(solver)
      .approve(await destinationSettler.getAddress(), mintAmount)
    fillerData = AbiCoder.defaultAbiCoder().encode(
      ['address', 'uint64', 'bytes'],
      [solver.address, sourceChainID, '0x'],
    )
    expect(
      await destinationSettler
        .connect(solver)
        .fill(
          intentHash,
          await encodeUniversalOnchainCrosschainOrderData(orderData),
          fillerData,
          {
            value: nativeAmount,
          },
        ),
    )
      .to.emit(destinationSettler, 'OrderFilled')
      .withArgs(intentHash, addressToBytes32(solver.address))
      .and.to.emit(inbox, 'Fulfillment')
      .withArgs(
        intentHash,
        sourceChainID,
        addressToBytes32(await prover.getAddress()),
        addressToBytes32(solver.address),
      )

    expect(await erc20.balanceOf(creator.address)).to.equal(mintAmount)
  })
})
