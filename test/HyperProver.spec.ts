import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { HyperProver, Inbox, TestERC20, TestMailbox } from '../typechain-types'
import { encodeTransfer } from '../utils/encode'
import { hashIntent, TokenAmount } from './utils'

describe('HyperProver Test', (): void => {
  let inbox: Inbox
  let dispatcher: TestMailbox
  let hyperProver: HyperProver
  let token: TestERC20
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let claimant: SignerWithAddress
  const amount: number = 1234567890
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  async function deployHyperproverFixture(): Promise<{
    inbox: Inbox
    token: TestERC20
    owner: SignerWithAddress
    solver: SignerWithAddress
    claimant: SignerWithAddress
  }> {
    const [owner, solver, claimant] = await ethers.getSigners()
    dispatcher = await (
      await ethers.getContractFactory('TestMailbox')
    ).deploy(await owner.getAddress())

    const inbox = await (
      await ethers.getContractFactory('Inbox')
    ).deploy(owner.address, true, [])

    const token = await (
      await ethers.getContractFactory('TestERC20')
    ).deploy('token', 'tkn')

    return {
      inbox,
      token,
      owner,
      solver,
      claimant,
    }
  }

  beforeEach(async (): Promise<void> => {
    ;({ inbox, token, owner, solver, claimant } = await loadFixture(
      deployHyperproverFixture,
    ))
  })
  describe('on prover implements interface', () => {
    it('should return the correct proof type', async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress())
      expect(await hyperProver.getProofType()).to.equal(1)
    })
  })
  describe('invalid', async () => {
    beforeEach(async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress())
    })
    it('should revert when msg.sender is not the mailbox', async () => {
      await expect(
        hyperProver
          .connect(solver)
          .handle(12345, ethers.sha256('0x'), ethers.sha256('0x')),
      ).to.be.revertedWithCustomError(hyperProver, 'UnauthorizedHandle')
    })
    it('should revert when sender field is not the inbox', async () => {
      await expect(
        hyperProver
          .connect(owner)
          .handle(12345, ethers.sha256('0x'), ethers.sha256('0x')),
      ).to.be.revertedWithCustomError(hyperProver, 'UnauthorizedDispatch')
    })
  })

  describe('valid instant', async () => {
    it('should handle the message if it comes from the correct inbox and mailbox', async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress())

      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [claimantAddress]],
      )
      expect(await hyperProver.provenIntents(intentHash)).to.eq(
        ethers.ZeroAddress,
      )
      await expect(
        hyperProver
          .connect(owner)
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
          ),
      )
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress)
      expect(await hyperProver.provenIntents(intentHash)).to.eq(claimantAddress)
    })
    it('works end to end', async () => {
      await inbox.connect(owner).setMailbox(await dispatcher.getAddress())
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await dispatcher.getAddress(), await inbox.getAddress())
      await token.mint(solver.address, amount)
      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const nonce = ethers.encodeBytes32String('0x987')

      const route = {
        nonce: nonce,
        source: sourceChainID,
        destination: Number(
          (await hyperProver.runner?.provider?.getNetwork())?.chainId,
        ),
        inbox: await inbox.getAddress(),
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
        prover: await hyperProver.getAddress(),
        expiryTime: timeStamp + 1000,
        nativeValue: 1n,
        tokens: [] as TokenAmount[],
      }

      const { intentHash, rewardHash } = hashIntent({ route, reward })
      const fulfillData = [
        route,
        rewardHash,
        await claimant.getAddress(),
        intentHash,
        await hyperProver.getAddress(),
      ]
      await token.connect(solver).transfer(await inbox.getAddress(), amount)

      expect(await hyperProver.provenIntents(intentHash)).to.eq(
        ethers.ZeroAddress,
      )
      await expect(
        dispatcher.dispatch(
          12345,
          ethers.zeroPadValue(await hyperProver.getAddress(), 32),
          calldata,
        ),
      ).to.be.revertedWithCustomError(hyperProver, 'UnauthorizedDispatch')
      const msgbody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [await claimant.getAddress()]],
      )
      const fee = await inbox.fetchFee(
        sourceChainID,
        ethers.zeroPadValue(await hyperProver.getAddress(), 32),
        msgbody,
        msgbody, // does nothing if postDispatchHook is the zero address
        ethers.ZeroAddress,
      )
      await expect(
        inbox.connect(solver).fulfillHyperInstant(...fulfillData, {
          value: fee,
        }),
      )
        .to.emit(hyperProver, `IntentProven`)
        .withArgs(intentHash, await claimant.getAddress())
      expect(await hyperProver.provenIntents(intentHash)).to.eq(
        await claimant.getAddress(),
      )
    })
  })
  describe('valid batched', async () => {
    it('should emit if intent is already proven', async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress())
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [claimantAddress]],
      )
      await hyperProver
        .connect(owner)
        .handle(
          12345,
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgBody,
        )

      await expect(
        hyperProver
          .connect(owner)
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
          ),
      )
        .to.emit(hyperProver, 'IntentAlreadyProven')
        .withArgs(intentHash)
    })
    it('should work with a batch', async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress())
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
        hyperProver
          .connect(owner)
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
          ),
      )
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress)
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(otherHash, otherAddress)
    })
    it('should work end to end', async () => {
      await inbox.connect(owner).setMailbox(await dispatcher.getAddress())
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await dispatcher.getAddress(), await inbox.getAddress())
      await token.mint(solver.address, 2 * amount)
      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      let nonce = ethers.encodeBytes32String('0x987')
      const route = {
        nonce: nonce,
        source: sourceChainID,
        destination: Number(
          (await hyperProver.runner?.provider?.getNetwork())?.chainId,
        ),
        inbox: await inbox.getAddress(),
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
        prover: await hyperProver.getAddress(),
        expiryTime: timeStamp + 1000,
        nativeValue: 1n,
        tokens: [],
      }

      const { intentHash: intentHash0, rewardHash: rewardHash0 } = hashIntent({
        route,
        reward,
      })

      const fulfillData0 = [
        route,
        rewardHash0,
        await claimant.getAddress(),
        intentHash0,
        await hyperProver.getAddress(),
      ]
      await token.connect(solver).transfer(await inbox.getAddress(), amount)

      expect(await hyperProver.provenIntents(intentHash0)).to.eq(
        ethers.ZeroAddress,
      )

      await expect(inbox.connect(solver).fulfillHyperBatched(...fulfillData0))
        .to.emit(inbox, `AddToBatch`)
        .withArgs(
          intentHash0,
          sourceChainID,
          await claimant.getAddress(),
          await hyperProver.getAddress(),
        )

      nonce = ethers.encodeBytes32String('0x1234')
      const route1 = {
        nonce: nonce,
        source: sourceChainID,
        destination: Number(
          (await hyperProver.runner?.provider?.getNetwork())?.chainId,
        ),
        inbox: await inbox.getAddress(),
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
        prover: await hyperProver.getAddress(),
        expiryTime: timeStamp + 1000,
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
        await hyperProver.getAddress(),
      ]

      await token.connect(solver).transfer(await inbox.getAddress(), amount)

      await expect(inbox.connect(solver).fulfillHyperBatched(...fulfillData1))
        .to.emit(inbox, `AddToBatch`)
        .withArgs(
          intentHash1,
          sourceChainID,
          await claimant.getAddress(),
          await hyperProver.getAddress(),
        )
      expect(await hyperProver.provenIntents(intentHash1)).to.eq(
        ethers.ZeroAddress,
      )

      const msgbody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [
          [intentHash0, intentHash1],
          [await claimant.getAddress(), await claimant.getAddress()],
        ],
      )

      const fee = await inbox.fetchFee(
        sourceChainID,
        ethers.zeroPadValue(await hyperProver.getAddress(), 32),
        msgbody,
        msgbody, // does nothing if postDispatchHook is the zero address
        ethers.ZeroAddress,
      )

      await expect(
        inbox
          .connect(solver)
          .sendBatch(
            sourceChainID,
            await hyperProver.getAddress(),
            [intentHash0, intentHash1],
            { value: fee },
          ),
      )
        .to.emit(hyperProver, `IntentProven`)
        .withArgs(intentHash0, await claimant.getAddress())
        .to.emit(hyperProver, `IntentProven`)
        .withArgs(intentHash1, await claimant.getAddress())

      expect(await hyperProver.provenIntents(intentHash0)).to.eq(
        await claimant.getAddress(),
      )
      expect(await hyperProver.provenIntents(intentHash1)).to.eq(
        await claimant.getAddress(),
      )
    })
  })
})
