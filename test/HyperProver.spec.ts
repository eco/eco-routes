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
  let mailbox: TestMailbox
  let hyperProver: HyperProver
  let token: TestERC20
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let claimant: SignerWithAddress
  const amount: number = 1234567890
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  async function deployHyperproverFixture(): Promise<{
    inbox: Inbox
    mailbox: TestMailbox
    token: TestERC20
    owner: SignerWithAddress
    solver: SignerWithAddress
    claimant: SignerWithAddress
  }> {
    const [owner, solver, claimant] = await ethers.getSigners()
    const mailbox = await (
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
      mailbox,
      token,
      owner,
      solver,
      claimant,
    }
  }

  beforeEach(async (): Promise<void> => {
    ;({ inbox, mailbox, token, owner, solver, claimant } = await loadFixture(
      deployHyperproverFixture,
    ))
  })

  describe('1. Constructor', () => {
    it('should initialize with the correct mailbox and inbox addresses', async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await mailbox.getAddress(), await inbox.getAddress(), [])

      expect(await hyperProver.MAILBOX()).to.equal(await mailbox.getAddress())
      expect(await hyperProver.INBOX()).to.equal(await inbox.getAddress())
    })

    it('should add constructor-provided provers to the whitelist', async () => {
      const additionalProver = await owner.getAddress()

      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await mailbox.getAddress(), await inbox.getAddress(), [
        additionalProver,
      ])

      // HyperProver whitelists itself
      expect(await hyperProver.proverWhitelist(await hyperProver.getAddress()))
        .to.be.true
      // And whitelists the provided address
      expect(await hyperProver.proverWhitelist(additionalProver)).to.be.true
    })

    it('should return the correct proof type', async () => {
      // use owner as mailbox so we can test handle
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await mailbox.getAddress(), await inbox.getAddress(), [])
      expect(await hyperProver.getProofType()).to.equal('Hyperlane')
    })
  })

  describe('2. Handle', () => {
    beforeEach(async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(owner.address, await inbox.getAddress(), [
        await inbox.getAddress(),
      ])
    })

    it('should revert when msg.sender is not the mailbox', async () => {
      await expect(
        hyperProver
          .connect(claimant)
          .handle(12345, ethers.sha256('0x'), ethers.sha256('0x')),
      ).to.be.revertedWithCustomError(hyperProver, 'UnauthorizedHandle')
    })

    it('should revert when sender field is not authorized', async () => {
      await expect(
        hyperProver
          .connect(owner)
          .handle(12345, ethers.sha256('0x'), ethers.sha256('0x')),
      ).to.be.revertedWithCustomError(
        hyperProver,
        'UnauthorizedInitiateProving',
      )
    })

    it('should record a single proven intent when called correctly', async () => {
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

    it('should emit an event when intent is already proven', async () => {
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [claimantAddress]],
      )

      // First handle call proves the intent
      await hyperProver
        .connect(owner)
        .handle(
          12345,
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgBody,
        )

      // Second handle call should emit IntentAlreadyProven
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

    it('should handle batch proving of multiple intents', async () => {
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

      expect(await hyperProver.provenIntents(intentHash)).to.eq(claimantAddress)
      expect(await hyperProver.provenIntents(otherHash)).to.eq(otherAddress)
    })
  })

  describe('3. InitiateProving', () => {
    beforeEach(async () => {
      // use owner as inbox so we can test initiateProving
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await mailbox.getAddress(), owner.address, [
        await inbox.getAddress(),
      ])
      await inbox.connect(owner).setMailbox(await mailbox.getAddress())
    })

    it('should reject initiateProving from unauthorized source', async () => {
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes', 'address'],
        ['0x', ethers.ZeroAddress],
      )

      await expect(
        hyperProver
          .connect(solver)
          .initiateProving(
            123,
            intentHashes,
            claimants,
            sourceChainProver,
            data,
          ),
      ).to.be.revertedWithCustomError(
        hyperProver,
        'UnauthorizedInitiateProving',
      )
    })

    it('should correctly call dispatch in the initiateProving method', async () => {
      // Set up test data
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await hyperProver.getAddress()
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes', 'address'],
        [metadata, ethers.ZeroAddress],
      )

      // Before initiateProving, make sure the mailbox hasn't been called
      expect(await mailbox.dispatchedWithRelayer()).to.be.false

      await expect(
        hyperProver.connect(owner).initiateProving(
          sourceChainId,
          intentHashes,
          claimants,
          sourceChainProver,
          data,
          { value: 1000000 }, // Send some value to cover fees
        ),
      )
        .to.emit(hyperProver, 'BatchSent')
        .withArgs(intentHashes[0], sourceChainId)

      // Verify the mailbox was called with correct parameters
      expect(await mailbox.dispatchedWithRelayer()).to.be.true
      expect(await mailbox.destinationDomain()).to.eq(sourceChainId)
      expect(await mailbox.recipientAddress()).to.eq(
        ethers.zeroPadValue(sourceChainProver, 32),
      )

      // Verify message encoding is correct
      const expectedBody = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32[]', 'address[]'],
        [intentHashes, claimants],
      )
      expect(await mailbox.messageBody()).to.eq(expectedBody)
    })

    it('should correctly format parameters in processAndFormat via fetchFee', async () => {
      // Since processAndFormat is internal, we'll test through fetchFee
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const metadata = '0x1234'
      const hookAddress = ethers.ZeroAddress
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes', 'address'],
        [metadata, hookAddress],
      )

      // Call fetchFee which uses processAndFormat internally
      const fee = await hyperProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        sourceChainProver,
        data,
      )

      // Verify we get a valid fee (implementation dependent, so just check it's non-zero)
      expect(fee).to.be.gt(0)
    })
  })

  describe('4. End-to-End', () => {
    it('works end to end with message bridge', async () => {
      await inbox.connect(owner).setMailbox(await mailbox.getAddress())
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await mailbox.getAddress(), await inbox.getAddress(), [
        await inbox.getAddress(),
      ])
      await token.mint(solver.address, amount)

      // Set up intent data
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

      // Prepare message data
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes', 'address'],
        [metadata, ethers.ZeroAddress],
      )

      await token.connect(solver).approve(await inbox.getAddress(), amount)

      expect(await hyperProver.provenIntents(intentHash)).to.eq(
        ethers.ZeroAddress,
      )

      // Get fee for fulfillment
      const fee = await hyperProver.fetchFee(
        sourceChainID,
        [intentHash],
        [await claimant.getAddress()],
        await hyperProver.getAddress(),
        data,
      )

      // Fulfill the intent using message bridge
      await inbox
        .connect(solver)
        .fulfillMessageBridge(
          route,
          rewardHash,
          await claimant.getAddress(),
          intentHash,
          await hyperProver.getAddress(),
          await hyperProver.getAddress(),
          data,
          { value: fee },
        )

      //the testMailbox's dispatch method directly calls the hyperProver's handle method
      expect(await hyperProver.provenIntents(intentHash)).to.eq(
        await claimant.getAddress(),
      )

      //but lets simulate it fully anyway

      // Simulate the message being handled on the destination chain
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [await claimant.getAddress()]],
      )

      // For the end-to-end test, we need to simulate the mailbox
      // by deploying a new hyperProver with owner as the mailbox
      const simulatedHyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress(), [
        await inbox.getAddress(),
      ])

      // Handle the message and verify the intent is proven
      await expect(
        simulatedHyperProver
          .connect(owner) // Owner simulates the mailbox
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
          ),
      )
        .to.emit(simulatedHyperProver, 'IntentProven')
        .withArgs(intentHash, await claimant.getAddress())

      expect(await simulatedHyperProver.provenIntents(intentHash)).to.eq(
        await claimant.getAddress(),
      )
    })

    it('should work with batched message bridge fulfillment end-to-end', async () => {
      await inbox.connect(owner).setMailbox(await mailbox.getAddress())
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await mailbox.getAddress(), await inbox.getAddress(), [
        await inbox.getAddress(),
      ])

      // Set up token and mint
      await token.mint(solver.address, 2 * amount)

      // Set up common data
      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes', 'address'],
        [metadata, ethers.ZeroAddress],
      )

      // Create first intent
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

      // Approve tokens and check initial state
      await token.connect(solver).approve(await inbox.getAddress(), amount)
      expect(await hyperProver.provenIntents(intentHash0)).to.eq(
        ethers.ZeroAddress,
      )

      // Fulfill first intent in batch
      await expect(
        inbox
          .connect(solver)
          .fulfillMessageBridgeBatched(
            route,
            rewardHash0,
            await claimant.getAddress(),
            intentHash0,
            await hyperProver.getAddress(),
            await hyperProver.getAddress(),
          ),
      )
        .to.emit(inbox, 'AddToBatch')
        .withArgs(
          intentHash0,
          sourceChainID,
          await claimant.getAddress(),
          await hyperProver.getAddress(),
          await hyperProver.getAddress(),
        )

      // Create second intent
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

      // Approve tokens and fulfill second intent in batch
      await token.connect(solver).approve(await inbox.getAddress(), amount)
      await expect(
        inbox
          .connect(solver)
          .fulfillMessageBridgeBatched(
            route1,
            rewardHash1,
            await claimant.getAddress(),
            intentHash1,
            await hyperProver.getAddress(),
            await hyperProver.getAddress(),
          ),
      ).to.emit(inbox, 'AddToBatch')

      // Check intent hasn't been proven yet
      expect(await hyperProver.provenIntents(intentHash1)).to.eq(
        ethers.ZeroAddress,
      )

      // Prepare message body for batch
      const msgbody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [
          [intentHash0, intentHash1],
          [await claimant.getAddress(), await claimant.getAddress()],
        ],
      )

      // Get fee for batch
      const fee = await hyperProver.fetchFee(
        sourceChainID,
        [intentHash0, intentHash1],
        [await claimant.getAddress(), await claimant.getAddress()],
        await hyperProver.getAddress(),
        data,
      )

      // Send batch to message bridge
      await expect(
        inbox
          .connect(solver)
          .messageBridgeSendBatch(
            sourceChainID,
            await hyperProver.getAddress(),
            [intentHash0, intentHash1],
            await hyperProver.getAddress(),
            await hyperProver.getAddress(),
            data,
            { value: fee },
          ),
      ).to.changeEtherBalance(solver, -Number(fee))

      //the testMailbox's dispatch method directly calls the hyperProver's handle method
      expect(await hyperProver.provenIntents(intentHash0)).to.eq(
        await claimant.getAddress(),
      )
      expect(await hyperProver.provenIntents(intentHash1)).to.eq(
        await claimant.getAddress(),
      )

      //but lets simulate it fully anyway

      // For the end-to-end test, we need to simulate the mailbox
      // by deploying a new hyperProver with owner as the mailbox
      const simulatedHyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress(), [
        await inbox.getAddress(),
      ])

      // Simulate handling of the batch message
      await expect(
        simulatedHyperProver
          .connect(owner) // Owner simulates the mailbox
          .handle(
            12345,
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgbody,
          ),
      )
        .to.emit(simulatedHyperProver, 'IntentProven')
        .withArgs(intentHash0, await claimant.getAddress())
        .to.emit(simulatedHyperProver, 'IntentProven')
        .withArgs(intentHash1, await claimant.getAddress())

      // Verify both intents were proven
      expect(await simulatedHyperProver.provenIntents(intentHash0)).to.eq(
        await claimant.getAddress(),
      )
      expect(await simulatedHyperProver.provenIntents(intentHash1)).to.eq(
        await claimant.getAddress(),
      )
    })
  })
})
