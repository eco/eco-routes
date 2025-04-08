import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import {
  MetaProver,
  Inbox,
  TestERC20,
  TestMetaRouter,
} from '../typechain-types'
import { encodeTransfer } from '../utils/encode'
import { hashIntent, TokenAmount } from '../utils/intent'

describe('MetaProver Test', (): void => {
  let inbox: Inbox
  let router: TestMetaRouter
  let metaProver: MetaProver
  let token: TestERC20
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let claimant: SignerWithAddress
  const amount: number = 1234567890
  const minBatcherReward = 12345
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  async function deployMetaproverFixture(): Promise<{
    inbox: Inbox
    router: TestMetaRouter
    token: TestERC20
    owner: SignerWithAddress
    solver: SignerWithAddress
    claimant: SignerWithAddress
  }> {
    const [owner, solver, claimant] = await ethers.getSigners()

    const TestMetaRouterFactory =
      await ethers.getContractFactory('TestMetaRouter')
    const router = (await TestMetaRouterFactory.deploy(
      await owner.getAddress(),
    )) as unknown as TestMetaRouter
    await router.waitForDeployment()

    const InboxFactory = await ethers.getContractFactory('Inbox')
    const inbox = (await InboxFactory.deploy(
      owner.address,
      true,
      minBatcherReward,
      [],
    )) as unknown as Inbox
    await inbox.waitForDeployment()

    const TestERC20Factory = await ethers.getContractFactory('TestERC20')
    const token = (await TestERC20Factory.deploy(
      'token',
      'tkn',
    )) as unknown as TestERC20
    await token.waitForDeployment()

    return {
      inbox,
      router,
      token,
      owner,
      solver,
      claimant,
    }
  }

  beforeEach(async (): Promise<void> => {
    ;({ inbox, router, token, owner, solver, claimant } = await loadFixture(
      deployMetaproverFixture,
    ))
  })

  describe('on prover implements interface', () => {
    it('should return the correct proof type', async () => {
      const MetaProverFactory = await ethers.getContractFactory('MetaProver')
      metaProver = (await MetaProverFactory.deploy(
        await router.getAddress(),
        await inbox.getAddress(),
      )) as unknown as MetaProver
      await metaProver.waitForDeployment()
      const proofType = await metaProver.getProofType()
      expect(proofType).to.equal(2)
    })
  })
  describe('invalid', async () => {
    beforeEach(async () => {
      const MetaProverFactory = await ethers.getContractFactory('MetaProver')
      metaProver = (await MetaProverFactory.deploy(
        await owner.getAddress(),
        await inbox.getAddress(),
      )) as unknown as MetaProver
      await metaProver.waitForDeployment()
    })
    it('should revert when msg.sender is not the router', async () => {
      await expect(
        metaProver
          .connect(solver)
          .handle(12345, ethers.sha256('0x'), ethers.sha256('0x'), [], []),
      ).to.be.revertedWithCustomError(metaProver, 'UnauthorizedHandle')
    })
    it('should revert when sender field is not the inbox', async () => {
      await expect(
        metaProver
          .connect(owner)
          .handle(12345, ethers.sha256('0x'), ethers.sha256('0x'), [], []),
      ).to.be.revertedWithCustomError(metaProver, 'UnauthorizedDispatch')
    })
  })

  describe('valid instant', async () => {
    it('should handle the message if it comes from the correct inbox and router', async () => {
      const MetaProverFactory = await ethers.getContractFactory('MetaProver')
      metaProver = await MetaProverFactory.deploy(
        await owner.getAddress(),
        await inbox.getAddress(),
      )
      await metaProver.waitForDeployment()

      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [claimantAddress]],
      )
      expect(await metaProver.provenIntents(intentHash)).to.eq(
        ethers.ZeroAddress,
      )
      await expect(
        metaProver
          .connect(owner)
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
            [],
            [],
          ),
      )
        .to.emit(metaProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress)
      expect(await metaProver.provenIntents(intentHash)).to.eq(claimantAddress)
    })
    it('works end to end', async () => {
      await inbox.connect(owner).setRouter(await router.getAddress())

      const MetaProverFactory = await ethers.getContractFactory('MetaProver')
      metaProver = (await MetaProverFactory.deploy(
        await router.getAddress(),
        await inbox.getAddress(),
      )) as unknown as MetaProver
      await metaProver.waitForDeployment()

      await token.mint(solver.address, amount)

      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const salt = ethers.encodeBytes32String('0x987')
      const routeTokens = [{ token: await token.getAddress(), amount: amount }]
      const route = {
        salt: salt,
        source: sourceChainID,
        destination: Number(
          (await metaProver.runner?.provider?.getNetwork())?.chainId,
        ),
        inbox: await inbox.getAddress(),
        tokens: routeTokens,
        calls: [
          {
            target: await token.getAddress(),
            data: calldata,
            value: 0,
          },
        ],
      }
      const reward = {
        creator: await owner.getAddress(),
        prover: await metaProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeValue: 1n,
        tokens: [] as TokenAmount[],
      }

      const { intentHash, rewardHash } = hashIntent({ route, reward })

      const fulfillData = [
        route,
        rewardHash,
        await claimant.getAddress(),
        intentHash,
        await metaProver.getAddress(),
      ]

      await token.connect(solver).approve(await inbox.getAddress(), amount)

      expect(await metaProver.provenIntents(intentHash)).to.eq(
        ethers.ZeroAddress,
      )
      const msgbody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [await claimant.getAddress()]],
      )
      const fee = await inbox.fetchMetalayerFee(
        sourceChainID,
        ethers.zeroPadValue(await metaProver.getAddress(), 32),
        msgbody,
      )

      await expect(
        router.dispatch(
          12345,
          await metaProver.getAddress(),
          [], // reads
          msgbody, // writeCallData
          0, // FinalityState.INSTANT
          300000, // gas limit
          { value: await router.FEE() },
        ),
      ).to.be.revertedWithCustomError(metaProver, 'UnauthorizedDispatch')

      await expect(
        inbox
          .connect(solver)
          .fulfillMetaInstant(...fulfillData, { value: fee }),
      )
        .to.emit(metaProver, `IntentProven`)
        .withArgs(intentHash, await claimant.getAddress())
      expect(await metaProver.provenIntents(intentHash)).to.eq(
        await claimant.getAddress(),
      )
    })
  })
  describe('valid batched', async () => {
    it('should emit if intent is already proven', async () => {
      const MetaProverFactory = await ethers.getContractFactory('MetaProver')
      metaProver = await MetaProverFactory.deploy(
        await owner.getAddress(),
        await inbox.getAddress(),
      )
      await metaProver.waitForDeployment()
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [claimantAddress]],
      )
      await metaProver
        .connect(owner)
        .handle(
          12345,
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgBody,
          [],
          [],
        )

      await expect(
        metaProver
          .connect(owner)
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
            [],
            [],
          ),
      )
        .to.emit(metaProver, 'IntentAlreadyProven')
        .withArgs(intentHash)
    })
    it('should work with a batch', async () => {
      const MetaProverFactory = await ethers.getContractFactory('MetaProver')
      metaProver = await MetaProverFactory.deploy(
        await owner.getAddress(),
        await inbox.getAddress(),
      )
      await metaProver.waitForDeployment()
      const intentHash = ethers.sha256('0x')
      const otherHash = ethers.sha256('0x1337')
      const claimantAddress = await claimant.getAddress()
      const otherAddress = await solver.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [
          [intentHash, otherHash],
          [claimantAddress, otherAddress],
        ],
      )

      await expect(
        metaProver
          .connect(owner)
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
            [],
            [],
          ),
      )
        .to.emit(metaProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress)
        .to.emit(metaProver, 'IntentProven')
        .withArgs(otherHash, otherAddress)
    })
    it('should work end to end', async () => {
      await inbox.connect(owner).setRouter(await router.getAddress())
      const MetaProverFactory = await ethers.getContractFactory('MetaProver')
      metaProver = await MetaProverFactory.deploy(
        await router.getAddress(),
        await inbox.getAddress(),
      )
      await metaProver.waitForDeployment()
      await token.mint(solver.address, 2 * amount)
      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      let salt = ethers.encodeBytes32String('0x987')
      const routeTokens: TokenAmount[] = [
        { token: await token.getAddress(), amount: amount },
      ]
      const route = {
        salt: salt,
        source: sourceChainID,
        destination: Number(
          (await metaProver.runner?.provider?.getNetwork())?.chainId,
        ),
        inbox: await inbox.getAddress(),
        tokens: routeTokens,
        calls: [
          {
            target: await token.getAddress(),
            data: calldata,
            value: 0,
          },
        ],
      }
      const reward = {
        creator: await owner.getAddress(),
        prover: await metaProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeValue: 1n,
        tokens: [] as TokenAmount[],
      }

      const { intentHash: intentHash0, rewardHash: rewardHash0 } = hashIntent({
        route,
        reward,
      })

      const fulfillData0 = [
        route,
        rewardHash0,
        claimant.address,
        intentHash0,
        await metaProver.getAddress(),
        { value: minBatcherReward },
      ]
      await token.connect(solver).approve(await inbox.getAddress(), amount)

      expect(await metaProver.provenIntents(intentHash0)).to.eq(
        ethers.ZeroAddress,
      )

      await expect(inbox.connect(solver).fulfillMetaBatched(...fulfillData0))
        .to.emit(inbox, `AddToBatch`)
        .withArgs(
          intentHash0,
          sourceChainID,
          await claimant.getAddress(),
          await metaProver.getAddress(),
        )

      salt = ethers.encodeBytes32String('0x1234')
      const route1 = {
        salt: salt,
        source: sourceChainID,
        destination: Number(
          (await metaProver.runner?.provider?.getNetwork())?.chainId,
        ),
        inbox: await inbox.getAddress(),
        tokens: routeTokens,
        calls: [
          {
            target: await token.getAddress(),
            data: calldata,
            value: 0,
          },
        ],
      }
      const reward1 = {
        creator: await owner.getAddress(),
        prover: await metaProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeValue: 1n,
        tokens: [],
      }
      const { intentHash: intentHash1, rewardHash: rewardHash1 } = hashIntent({
        route: route1,
        reward: reward1,
      })

      const fulfillData1 = [
        route1,
        rewardHash1,
        await claimant.getAddress(),
        intentHash1,
        await metaProver.getAddress(),
        { value: minBatcherReward },
      ]

      await token.connect(solver).approve(await inbox.getAddress(), amount)

      await expect(inbox.connect(solver).fulfillMetaBatched(...fulfillData1))
        .to.emit(inbox, `AddToBatch`)
        .withArgs(
          intentHash1,
          sourceChainID,
          await claimant.getAddress(),
          await metaProver.getAddress(),
        )
      expect(await metaProver.provenIntents(intentHash1)).to.eq(
        ethers.ZeroAddress,
      )

      const msgbody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [
          [intentHash0, intentHash1],
          [await claimant.getAddress(), await claimant.getAddress()],
        ],
      )

      const fee = await inbox.fetchMetalayerFee(
        sourceChainID,
        ethers.zeroPadValue(await metaProver.getAddress(), 32),
        msgbody,
      )

      await expect(
        inbox
          .connect(solver)
          .sendMetaBatch(
            sourceChainID,
            await metaProver.getAddress(),
            [intentHash0, intentHash1],
            { value: fee },
          ),
      )
        .to.emit(metaProver, `IntentProven`)
        .withArgs(intentHash0, await claimant.getAddress())
        .to.emit(metaProver, `IntentProven`)
        .withArgs(intentHash1, await claimant.getAddress())

      expect(await metaProver.provenIntents(intentHash0)).to.eq(
        await claimant.getAddress(),
      )
      expect(await metaProver.provenIntents(intentHash1)).to.eq(
        await claimant.getAddress(),
      )
    })
  })
})
