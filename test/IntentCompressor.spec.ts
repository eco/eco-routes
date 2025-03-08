import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  TestERC20,
  IntentSource,
  TestProver,
  Inbox,
  IntentCompressor,
} from '../typechain-types'
import { loadFixture } from '@nomicfoundation/hardhat-network-helpers'
import { EncodedFulfillmentStruct, EncodedIntentStruct } from '../typechain-types/contracts/compressor/IntentCompressor'

describe('Intent Compressor Test', (): void => {
  let intentSource: IntentSource
  let prover: TestProver
  let compressor: IntentCompressor
  let inbox: Inbox
  let tokenA: TestERC20
  let tokenB: TestERC20
  let creator: SignerWithAddress
  let claimant: SignerWithAddress
  let otherPerson: SignerWithAddress
  const mintAmount: number = 1000

  enum ChainIdIndex {
    ETHEREUM,
    OPTIMISM,
    POLYGON,
    BASE,
    MANTLE,
    ARBITRUM,
  }

  enum TokenIndex {
    ETH_USDC,
    ETH_USDT,
    OP_USDC,
    OP_USDT,
    OP_USDCe,
    POL_USDC,
    POL_USDT,
    POL_USDCe,
    BASE_USDC,
    BASE_USDbC,
    MNT_USDC,
    MNT_USDT,
    ARB_USDC,
    ARB_USDT,
    ARB_USDCe,
  }


  const createIntentData: EncodedIntentStruct = {
    sourceChainIndex: ChainIdIndex.BASE,
    destinationChainIndex: ChainIdIndex.OPTIMISM,
    rewardTokenIndex: TokenIndex.BASE_USDC,
    rewardAmount: (2n ** 48n) - 1n, // 1.01 MM
    routeTokenIndex: TokenIndex.OP_USDC,
    routeAmount: (2n ** 48n) - 1n, // 1 MM,
    expiryDuration: (2n ** 24n) - 1n,
    salt: '0x' + ((2n ** 64n) - 1n).toString(16),
  }


  let fulfillData: EncodedFulfillmentStruct;

  async function deploySourceFixture(): Promise<{
    intentSource: IntentSource
    prover: TestProver
    compressor: IntentCompressor
    tokenA: TestERC20
    tokenB: TestERC20
    creator: SignerWithAddress
    claimant: SignerWithAddress
    otherPerson: SignerWithAddress
  }> {
    const [creator, owner, claimant, otherPerson] = await ethers.getSigners()
    // deploy prover
    prover = await (await ethers.getContractFactory('TestProver')).deploy()

    const intentSourceFactory = await ethers.getContractFactory('IntentSource')
    const intentSource = await intentSourceFactory.deploy() as IntentSource
    inbox = await (
      await ethers.getContractFactory('Inbox')
    ).deploy(owner.address, false, [owner.address])

    compressor = await (
      await ethers.getContractFactory('IntentCompressor')
    ).deploy(await intentSource.getAddress(), await inbox.getAddress(), await prover.getAddress())

    // deploy ERC20 test
    const erc20Factory = await ethers.getContractFactory('TestERC20')
    const tokenA = await erc20Factory.deploy('A', 'A')
    const tokenB = await erc20Factory.deploy('B', 'B')

    fulfillData = {
      sourceChainIndex: ChainIdIndex.BASE,
      destinationChainIndex: ChainIdIndex.OPTIMISM,
      routeTokenIndex: TokenIndex.OP_USDC,
      routeAmount: (2n ** 48n) - 1n, // 1 MM,
      claimant: claimant.address,
      proveType: 1,
    }

    return {
      intentSource,
      compressor,
      prover,
      tokenA,
      tokenB,
      creator,
      claimant,
      otherPerson,
    }
  }

  async function mintAndApprove() {
    await tokenA.connect(creator).mint(creator.address, mintAmount)
    await tokenB.connect(creator).mint(creator.address, mintAmount * 2)

    await tokenA.connect(creator).approve(intentSource, mintAmount)
    await tokenB.connect(creator).approve(intentSource, mintAmount * 2)
  }

  function encodeIntentPayload(data: EncodedIntentStruct) {
    const packed = ethers.solidityPacked(
      ['uint8', 'uint8', 'uint8', 'uint48', 'uint8', 'uint48', 'uint24', 'bytes8'],
      [data.sourceChainIndex, data.destinationChainIndex, data.rewardTokenIndex, data.rewardAmount, data.routeTokenIndex, data.routeAmount, data.expiryDuration, data.salt]
    )
    return ethers.zeroPadBytes(packed, 32);
  }


  function encodeFulfillPayload(data: EncodedFulfillmentStruct) {
    const packed = ethers.solidityPacked(
      ['uint8', 'uint8', 'uint8', 'uint48', 'uint8', 'address'],
      [data.sourceChainIndex, data.destinationChainIndex, data.routeTokenIndex, data.routeAmount, data.proveType, data.claimant]
    )
    return ethers.zeroPadBytes(packed, 32);
  }

  beforeEach(async (): Promise<void> => {
    ; ({ intentSource, compressor, prover, tokenA, tokenB, creator, claimant, otherPerson } =
      await loadFixture(deploySourceFixture))

    // fund the creator and approve it to create an intent
    await mintAndApprove()
  })

  describe('intent creation', async () => {
    it('check encoded intent publish', async () => {
      const payload = encodeIntentPayload(createIntentData);
      const decodedIntent = await compressor.decodePublishPayload(payload);

      expect(decodedIntent[0]).to.eq(createIntentData.sourceChainIndex)
      expect(decodedIntent[1]).to.eq(createIntentData.destinationChainIndex)
      expect(decodedIntent[2]).to.eq(createIntentData.rewardTokenIndex)
      expect(decodedIntent[3]).to.eq(createIntentData.rewardAmount)
      expect(decodedIntent[4]).to.eq(createIntentData.routeTokenIndex)
      expect(decodedIntent[5]).to.eq(createIntentData.routeAmount)
      expect(decodedIntent[6]).to.eq(createIntentData.expiryDuration)
      expect(decodedIntent[7]).to.eq(createIntentData.salt)
    })

  })

  describe('fulfill', async () => {
    it('check encoded fulfill', async () => {
      const payload = encodeFulfillPayload(fulfillData);
      const decodedIntent = await compressor.decodeFulfillPayload(payload);

      expect(decodedIntent[0]).to.eq(fulfillData.sourceChainIndex)
      expect(decodedIntent[1]).to.eq(fulfillData.destinationChainIndex)
      expect(decodedIntent[2]).to.eq(fulfillData.routeTokenIndex)
      expect(decodedIntent[3]).to.eq(fulfillData.routeAmount)
      expect(decodedIntent[4]).to.eq(fulfillData.proveType)
      expect(decodedIntent[5]).to.eq(fulfillData.claimant)
    })

  })
})
