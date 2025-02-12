import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { HyperProver, Inbox, TestERC20, TestMailbox } from '../typechain-types'
import { encodeTransfer } from '../utils/encode'
import { hashIntent, TokenAmount } from '../utils/intent'

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

  enum MessageType {
    STANDARD = 0,
    COMPRESSED = 1,
  }

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

      const msg = abiCoder.encode(
        ['uint8', 'bytes'],
        [MessageType.STANDARD, msgBody],
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
            msg,
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
      const salt = ethers.encodeBytes32String('0x987')
      const routeTokens = [{ token: await token.getAddress(), amount: amount }]
      const route = {
        salt: salt,
        source: sourceChainID,
        destination: Number(
          (await hyperProver.runner?.provider?.getNetwork())?.chainId,
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
        prover: await hyperProver.getAddress(),
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
        await hyperProver.getAddress(),
      ]
      await token.connect(solver).approve(await inbox.getAddress(), amount)

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
      const msg = abiCoder.encode(
        ['uint8', 'bytes'],
        [MessageType.STANDARD, msgbody],
      )

      const fee = await inbox.fetchFee(
        sourceChainID,
        ethers.zeroPadValue(await hyperProver.getAddress(), 32),
        msg,
        msg, // does nothing if postDispatchHook is the zero address
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
      const msg = abiCoder.encode(
        ['uint8', 'bytes'],
        [MessageType.STANDARD, msgBody],
      )

      await hyperProver
        .connect(owner)
        .handle(12345, ethers.zeroPadValue(await inbox.getAddress(), 32), msg)

      await expect(
        hyperProver
          .connect(owner)
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msg,
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
      const msg = abiCoder.encode(
        ['uint8', 'bytes'],
        [MessageType.STANDARD, msgBody],
      )

      await expect(
        hyperProver
          .connect(owner)
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msg,
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
      let salt = ethers.encodeBytes32String('0x987')
      const routeTokens: TokenAmount[] = [
        { token: await token.getAddress(), amount: amount },
      ]
      const route = {
        salt: salt,
        source: sourceChainID,
        destination: Number(
          (await hyperProver.runner?.provider?.getNetwork())?.chainId,
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
        prover: await hyperProver.getAddress(),
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
        await claimant.getAddress(),
        intentHash0,
        await hyperProver.getAddress(),
      ]
      await token.connect(solver).approve(await inbox.getAddress(), amount)

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

      salt = ethers.encodeBytes32String('0x1234')
      const route1 = {
        salt: salt,
        source: sourceChainID,
        destination: Number(
          (await hyperProver.runner?.provider?.getNetwork())?.chainId,
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
        prover: await hyperProver.getAddress(),
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
        await hyperProver.getAddress(),
      ]

      await token.connect(solver).approve(await inbox.getAddress(), amount)

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

      const msg = abiCoder.encode(
        ['uint8', 'bytes'],
        [MessageType.STANDARD, msgbody],
      )

      const fee = await inbox.fetchFee(
        sourceChainID,
        ethers.zeroPadValue(await hyperProver.getAddress(), 32),
        msg,
        msg, // does nothing if postDispatchHook is the zero address
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

  describe('Valid Compressed Batched', () => {
    let hyperProver: HyperProver

    beforeEach(async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress())
    })

    it('should emit RootHashUnavailable if batch was already proven', async () => {
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const hashes = [intentHash]
      const claimats = [claimantAddress]
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [hashes, claimats],
      )
      const rootHash = ethers.keccak256(msgBody)
      const msg = abiCoder.encode(
        ['uint8', 'bytes'],
        [MessageType.COMPRESSED, rootHash],
      )
      const inboxAddress = ethers.zeroPadValue(await inbox.getAddress(), 32)

      await expect(
        await hyperProver.connect(owner).handle(12345, inboxAddress, msg),
      )
        .to.emit(hyperProver, 'RootHashReceived')
        .withArgs(rootHash)

      // Prove intents
      await hyperProver.connect(owner).proveCompressedBatch(hashes, claimats)

      await expect(
        hyperProver.connect(owner).proveCompressedBatch(hashes, claimats),
      ).to.be.revertedWithCustomError(hyperProver, 'RootHashUnavailable')
    })

    it('should work with a batch', async () => {
      const hashes = [ethers.sha256('0x'), ethers.sha256('0x1337')]
      const claimats = [await claimant.getAddress(), await solver.getAddress()]
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [hashes, claimats],
      )
      const rootHash = ethers.keccak256(msgBody)
      const msg = abiCoder.encode(
        ['uint8', 'bytes'],
        [MessageType.COMPRESSED, rootHash],
      )

      const inboxAddress = ethers.zeroPadValue(await inbox.getAddress(), 32)

      await hyperProver.connect(owner).handle(12345, inboxAddress, msg)

      await expect(
        hyperProver.connect(owner).proveCompressedBatch(hashes, claimats),
      )
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(hashes[0], claimats[0])
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(hashes[1], claimats[1])
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

      const createRoute = async (saltString: string) => ({
        salt: ethers.encodeBytes32String(saltString),
        source: sourceChainID,
        destination: Number(
          (await hyperProver.runner?.provider?.getNetwork())?.chainId,
        ),
        inbox: await inbox.getAddress(),
        calls: [{ target: await token.getAddress(), data: calldata, value: 0 }],
      })

      const createReward = async (deadlineOffset = 1000) => ({
        creator: await owner.getAddress(),
        prover: await hyperProver.getAddress(),
        deadline: timeStamp + deadlineOffset,
        nativeValue: 1n,
        tokens: [],
      })

      const [route0, reward0] = [
        await createRoute('0x987'),
        await createReward(),
      ]
      const { intentHash: intentHash0, rewardHash: rewardHash0 } = hashIntent({
        route: route0,
        reward: reward0,
      })

      const fulfillData0 = [
        route0,
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
        .to.emit(inbox, 'AddToBatch')
        .withArgs(
          intentHash0,
          sourceChainID,
          await claimant.getAddress(),
          await hyperProver.getAddress(),
        )

      const [route1, reward1] = [
        await createRoute('0x1234'),
        await createReward(),
      ]
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
        .to.emit(inbox, 'AddToBatch')
        .withArgs(
          intentHash1,
          sourceChainID,
          await claimant.getAddress(),
          await hyperProver.getAddress(),
        )
      expect(await hyperProver.provenIntents(intentHash1)).to.eq(
        ethers.ZeroAddress,
      )

      const hashes = [intentHash0, intentHash1]
      const claimants = [
        await claimant.getAddress(),
        await claimant.getAddress(),
      ]

      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [hashes, claimants],
      )
      const rootHash = ethers.keccak256(msgBody)
      const msg = abiCoder.encode(
        ['uint8', 'bytes'],
        [MessageType.COMPRESSED, rootHash],
      )

      const fee = await inbox.fetchFee(
        sourceChainID,
        ethers.zeroPadValue(await hyperProver.getAddress(), 32),
        msg,
        msg,
        ethers.ZeroAddress,
      )

      await expect(
        inbox
          .connect(solver)
          .sendCompressedBatch(
            sourceChainID,
            await hyperProver.getAddress(),
            hashes,
            { value: fee },
          ),
      )
        .to.emit(hyperProver, 'RootHashReceived')
        .withArgs(rootHash)

      await expect(
        hyperProver.connect(solver).proveCompressedBatch(hashes, claimants),
      )
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(intentHash0, await claimant.getAddress())
        .to.emit(hyperProver, 'IntentProven')
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
