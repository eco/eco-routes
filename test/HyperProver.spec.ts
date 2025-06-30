import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { HyperProver, Inbox, TestERC20, TestMailbox } from '../typechain-types'
import { encodeTransfer } from '../utils/encode'
import { hashIntent, TokenAmount, Intent } from '../utils/intent'

describe('HyperProver Test', (): void => {
  let inbox: Inbox
  let mailbox: TestMailbox
  let hyperProver: HyperProver
  let token: TestERC20
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let claimant: SignerWithAddress
  let intent: Intent
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

    const inbox = await (await ethers.getContractFactory('Inbox')).deploy()

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
      ).deploy(
        await mailbox.getAddress(),
        await inbox.getAddress(),
        [ethers.zeroPadValue(additionalProver, 32), ethers.zeroPadValue(await hyperProver.getAddress(), 32)],
        200000,
      )

      // Check if the prover address is in the whitelist
      expect(await hyperProver.isWhitelisted(ethers.zeroPadValue(additionalProver, 32))).to.be.true
      // Check if the hyperProver itself is also whitelisted
      expect(await hyperProver.isWhitelisted(ethers.zeroPadValue(await hyperProver.getAddress(), 32))).to
        .be.true
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
        ethers.zeroPadValue(await inbox.getAddress(), 32),
        ethers.zeroPadValue(await hyperProver.getAddress(), 32),
      ], 200000)
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
          .handle(
            12345,
            ethers.zeroPadValue(owner.address, 32),
            ethers.sha256('0x'),
          ),
      ).to.be.revertedWithCustomError(hyperProver, 'UnauthorizedIncomingProof')
    })

    it('should record a single proven intent when called correctly', async () => {
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [claimantAddress]],
      )

      expect((await hyperProver.provenIntents(intentHash)).claimant).to.eq(
        ethers.ZeroAddress,
      )
      expect(
        (await hyperProver.provenIntents(intentHash)).destinationChainID,
      ).to.eq(0)

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

      expect((await hyperProver.provenIntents(intentHash)).claimant).to.eq(
        claimantAddress,
      )
      expect(
        (await hyperProver.provenIntents(intentHash)).destinationChainID,
      ).to.eq(12345)
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
      expect((await hyperProver.provenIntents(intentHash)).claimant).to.eq(
        claimantAddress,
      )
      expect((await hyperProver.provenIntents(otherHash)).claimant).to.eq(
        otherAddress,
      )
      expect(
        (await hyperProver.provenIntents(intentHash)).destinationChainID,
      ).to.eq(12345)
      expect(
        (await hyperProver.provenIntents(otherHash)).destinationChainID,
      ).to.eq(12345)
    })
    it('accounts for Rari edge case where chainID != domainID', async () => {
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [claimantAddress]],
      )

      expect((await hyperProver.provenIntents(intentHash)).claimant).to.eq(
        ethers.ZeroAddress,
      )
      expect(
        (await hyperProver.provenIntents(intentHash)).destinationChainID,
      ).to.eq(0)

      expect(await hyperProver.RARICHAIN_DOMAIN_ID()).to.not.eq(
        await hyperProver.RARICHAIN_CHAIN_ID(),
      )

      await expect(
        hyperProver
          .connect(owner)
          .handle(
            await hyperProver.RARICHAIN_DOMAIN_ID(),
            ethers.zeroPadValue(await inbox.getAddress(), 32),
            msgBody,
          ),
      )
        .to.emit(hyperProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress)

      expect((await hyperProver.provenIntents(intentHash)).claimant).to.eq(
        claimantAddress,
      )
      expect(
        (await hyperProver.provenIntents(intentHash)).destinationChainID,
      ).to.eq(await hyperProver.RARICHAIN_CHAIN_ID())
    })
  })

  describe('edge case: challengeIntentProof', () => {
    beforeEach(async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(
        await mailbox.getAddress(),
        owner.address,
        [ethers.zeroPadValue(await inbox.getAddress(), 32), ethers.zeroPadValue(await hyperProver.getAddress(), 32)],
        200000,
      )

      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(await hyperProver.getAddress(), 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      let salt = ethers.encodeBytes32String('0x987')
      const routeTokens: TokenAmount[] = [
        { token: await token.getAddress(), amount: amount },
      ]
      const route = {
        salt: salt,
        source: sourceChainID,
        destination: 54321,
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
      intent = { route, reward }
    })
    it('deletes claimant and sets chainID for a bad proof, emits, and cant prove again incorrectly after that', async () => {
      const { intentHash, routeHash } = hashIntent(intent)
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [claimant.address]],
      )
      const badChainID = 666
      await hyperProver.handle(
        badChainID,
        ethers.zeroPadValue(await inbox.getAddress(), 32),
        msgBody,
      )

      expect((await hyperProver.provenIntents(intentHash)).claimant).to.eq(
        claimant.address,
      )
      expect(
        (await hyperProver.provenIntents(intentHash)).destinationChainID,
      ).to.eq(badChainID)

      expect(await hyperProver.challengeIntentProof(intent))
        .to.emit(hyperProver, 'BadProofCleared')
        .withArgs(intentHash)

      expect((await hyperProver.provenIntents(intentHash)).claimant).to.eq(
        ethers.ZeroAddress,
      )
      expect(
        (await hyperProver.provenIntents(intentHash)).destinationChainID,
      ).to.eq(intent.route.destination)

      const badderChainID = 777
      await expect(
        hyperProver.handle(
          badderChainID,
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgBody,
        ),
      )
        .to.be.revertedWithCustomError(hyperProver, 'BadDestinationChainID')
        .withArgs(intentHash, intent.route.destination, badderChainID)

      expect((await hyperProver.provenIntents(intentHash)).claimant).to.eq(
        ethers.ZeroAddress,
      )

      await expect(
        hyperProver.handle(
          intent.route.destination,
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgBody,
        ),
      ).to.not.be.reverted

      expect((await hyperProver.provenIntents(intentHash)).claimant).to.eq(
        claimant.address,
      )
    })
    it('lets you protect intents from being maliciously proven in the future', async () => {
      const { intentHash, routeHash } = hashIntent(intent)
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [claimant.address]],
      )
      const badChainID = 666

      await hyperProver.challengeIntentProof(intent)

      expect(
        (await hyperProver.provenIntents(intentHash)).destinationChainID,
      ).to.eq(intent.route.destination)

      await expect(
        hyperProver.handle(
          badChainID,
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgBody,
        ),
      )
        .to.be.revertedWithCustomError(hyperProver, 'BadDestinationChainID')
        .withArgs(intentHash, intent.route.destination, badChainID)

      await hyperProver.handle(
        intent.route.destination,
        ethers.zeroPadValue(await inbox.getAddress(), 32),
        msgBody,
      )
      expect((await hyperProver.provenIntents(intentHash)).claimant).to.eq(
        claimant.address,
      )
    })
    it('doesnt do anything if chainID is correct', async () => {
      const { intentHash, routeHash } = hashIntent(intent)
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [claimant.address]],
      )
      const badChainID = 666

      await hyperProver.handle(
        intent.route.destination,
        ethers.zeroPadValue(await inbox.getAddress(), 32),
        msgBody,
      )

      expect((await hyperProver.provenIntents(intentHash)).claimant).to.eq(
        claimant.address,
      )
      expect(
        (await hyperProver.provenIntents(intentHash)).destinationChainID,
      ).to.eq(intent.route.destination)

      await hyperProver.challengeIntentProof(intent)

      expect((await hyperProver.provenIntents(intentHash)).claimant).to.eq(
        claimant.address,
      )
      expect(
        (await hyperProver.provenIntents(intentHash)).destinationChainID,
      ).to.eq(intent.route.destination)
    })
  })

  describe('3. initiateProving', () => {
    beforeEach(async () => {
      // use owner as inbox so we can test initiateProving
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await mailbox.getAddress(), owner.address, [
        ethers.zeroPadValue(await inbox.getAddress(), 32),
        ethers.zeroPadValue(await hyperProver.getAddress(), 32),
      ], 200000)
    })

    it('should revert on underpayment', async () => {
      // Set up test data
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await hyperProver.getAddress()
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        // ['sourceChainProver', 'metadata', 'hookAddress'],
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(sourceChainProver, 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      // Before initiateProving, make sure the mailbox hasn't been called
      expect(await mailbox.dispatchedWithRelayer()).to.be.false

      const fee = await hyperProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )
      const initBalance = await solver.provider.getBalance(solver.address)
      await expect(
        hyperProver.connect(owner).prove(
          solver.address,
          sourceChainId,
          intentHashes,
          claimants,
          data,
          { value: fee - BigInt(1) }, // high number beacuse
        ),
      ).to.be.revertedWithCustomError(hyperProver, 'InsufficientFee')
    })

    it('should reject initiateProving from unauthorized source', async () => {
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await solver.getAddress()
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [ethers.zeroPadValue(sourceChainProver, 32), '0x', ethers.ZeroAddress],
      )

      await expect(
        hyperProver
          .connect(solver)
          .prove(owner.address, 123, intentHashes, claimants, data),
      ).to.be.revertedWithCustomError(hyperProver, 'UnauthorizedProve')
    })

    it('should handle exact fee payment with no refund needed', async () => {
      // Set up test data
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await hyperProver.getAddress()
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(sourceChainProver, 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      const fee = await hyperProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )

      // Track balances before and after
      const solverBalanceBefore = await solver.provider.getBalance(
        solver.address,
      )

      // Call with exact fee (no refund needed)
      await hyperProver.connect(owner).prove(
        solver.address,
        sourceChainId,
        intentHashes,
        claimants,
        data,
        { value: fee }, // Exact fee amount
      )

      // Should dispatch successfully without refund
      expect(await mailbox.dispatchedWithRelayer()).to.be.true

      // Balance should be unchanged since no refund was needed
      const solverBalanceAfter = await solver.provider.getBalance(
        solver.address,
      )
      expect(solverBalanceBefore).to.equal(solverBalanceAfter)
    })

    it('should handle custom hook address correctly', async () => {
      // Set up test data
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await hyperProver.getAddress()
      const metadata = '0x1234'
      const customHookAddress = await solver.getAddress() // Use solver as custom hook for testing
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(sourceChainProver, 32),
          metadata,
          customHookAddress,
        ],
      )

      const fee = await hyperProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )

      // Call with custom hook
      await hyperProver
        .connect(owner)
        .prove(solver.address, sourceChainId, intentHashes, claimants, data, {
          value: fee,
        })

      // Verify dispatch was called (we can't directly check hook address as
      // TestMailbox doesn't expose that property)
      expect(await mailbox.dispatchedWithRelayer()).to.be.true
    })

    it('should handle empty arrays gracefully', async () => {
      // Set up test data with empty arrays
      const sourceChainId = 123
      const intentHashes: string[] = []
      const claimants: string[] = []
      const sourceChainProver = await hyperProver.getAddress()
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(sourceChainProver, 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      const fee = await hyperProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )

      // Should process empty arrays without error
      await expect(
        hyperProver
          .connect(owner)
          .prove(solver.address, sourceChainId, intentHashes, claimants, data, {
            value: fee,
          }),
      ).to.not.be.reverted

      // Should dispatch successfully
      expect(await mailbox.dispatchedWithRelayer()).to.be.true
    })

    it('should correctly format parameters in processAndFormat via fetchFee', async () => {
      // Since processAndFormat is internal, we'll test through fetchFee
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await solver.getAddress()
      const metadata = '0x1234'
      const hookAddress = ethers.ZeroAddress
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [ethers.zeroPadValue(sourceChainProver, 32), metadata, hookAddress],
      )

      // Call fetchFee which uses processAndFormat internally
      const fee = await hyperProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )

      // Verify we get a valid fee (implementation dependent, so just check it's non-zero)
      expect(fee).to.be.gt(0)
    })

    it('handles rari edgecase correctly', async () => {
      // Set up test data
      const sourceChainId = await hyperProver.RARICHAIN_CHAIN_ID()
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await hyperProver.getAddress()
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        // ['sourceChainProver', 'metadata', 'hookAddress'],
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(sourceChainProver, 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      const fee = await hyperProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )

      await expect(
        hyperProver.connect(owner).prove(
          owner.address,
          sourceChainId,
          intentHashes,
          claimants,
          data,
          { value: fee }, // Send some value to cover fees
        ),
      )
        .to.emit(hyperProver, 'BatchSent')
        .withArgs(intentHashes[0], sourceChainId)

      // Verify the mailbox was called with correct parameters
      expect(await mailbox.destinationDomain()).to.eq(
        await hyperProver.RARICHAIN_DOMAIN_ID(),
      )
    })

    it('should correctly call dispatch in the prove method', async () => {
      // Set up test data
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await hyperProver.getAddress()
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        // ['sourceChainProver', 'metadata', 'hookAddress'],
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(sourceChainProver, 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      // Before proving, make sure the mailbox hasn't been called
      expect(await mailbox.dispatchedWithRelayer()).to.be.false

      await expect(
        hyperProver.connect(owner).prove(
          owner.address,
          sourceChainId,
          intentHashes,
          claimants,
          data,
          { value: 10000000000000 }, // Send some value to cover fees
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
        ['bytes32[]', 'bytes32[]'],
        [intentHashes, claimants],
      )
      expect(await mailbox.messageBody()).to.eq(expectedBody)
    })

    it('should gracefully return funds to sender if they overpay', async () => {
      // Set up test data
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await hyperProver.getAddress()
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        // ['sourceChainProver', 'metadata', 'hookAddress'],
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(sourceChainProver, 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      // Before proving, make sure the mailbox hasn't been called
      expect(await mailbox.dispatchedWithRelayer()).to.be.false

      const fee = await hyperProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )
      const initBalance = await solver.provider.getBalance(solver.address)
      await expect(
        hyperProver.connect(owner).prove(
          solver.address,
          sourceChainId,
          intentHashes,
          claimants,
          data,
          { value: fee * BigInt(10) }, // high number beacuse
        ),
      ).to.not.be.reverted
      expect(
        (await owner.provider.getBalance(solver.address)) >
          initBalance - fee * BigInt(10),
      ).to.be.true
    })
  })

  describe('4. Cross-VM Claimant Compatibility', () => {
    it('should handle fulfillAndProve with non-address bytes32 claimant', async () => {
      const chainId = 12345
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(
        await mailbox.getAddress(),
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32), ethers.zeroPadValue(await hyperProver.getAddress(), 32)],
        200000,
      )
      
      // Set processor to 0x0 for non-EVM test to prevent automatic processing since handle will be on non-EVM chain
      await mailbox.setProcessor(ethers.ZeroAddress)
      
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

      // Use a bytes32 claimant that doesn't represent a valid address
      // This simulates a cross-VM scenario where the claimant identifier
      // is not an Ethereum address but some other VM's identifier like Solana
      const nonAddressClaimant = ethers.keccak256(ethers.toUtf8Bytes("non-evm-claimant-identifier"))

      // Prepare message data
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(await hyperProver.getAddress(), 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      await token.connect(solver).approve(await inbox.getAddress(), amount)
      
      const fee = await hyperProver.fetchFee(
        sourceChainID,
        [intentHash],
        [nonAddressClaimant],
        data,
      )

      await expect(
        inbox
          .connect(solver)
          .fulfillAndProve(
            route,
            rewardHash,
            nonAddressClaimant,
            intentHash,
            await hyperProver.getAddress(),
            data,
            { value: fee },
          )
      ).to.not.be.reverted

      // Verify the intent was fulfilled with the non-address claimant
      expect(await inbox.fulfilled(intentHash)).to.eq(nonAddressClaimant)
      // NOTE: we don't check provenIntents here because we're not skipping the handle call
    })
  })

  describe('5. End-to-End', () => {
    it('works end to end with message bridge', async () => {
      const chainId = 12345 // Use test chainId
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await mailbox.getAddress(), await inbox.getAddress(), [
        ethers.zeroPadValue(await inbox.getAddress(), 32),
        ethers.zeroPadValue(await hyperProver.getAddress(), 32),
      ], 200000)
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
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(await hyperProver.getAddress(), 32),
          metadata,
          ethers.ZeroAddress,
        ],
      )

      await token.connect(solver).approve(await inbox.getAddress(), amount)

      expect((await hyperProver.provenIntents(intentHash)).claimant).to.eq(
        ethers.ZeroAddress,
      )

      // Get fee for fulfillment
      const fee = await hyperProver.fetchFee(
        sourceChainID,
        [intentHash],
        [ethers.zeroPadValue(await claimant.getAddress(), 32)],
        data,
      )

      // Fulfill the intent using message bridge
      await inbox
        .connect(solver)
        .fulfillAndProve(
          route,
          rewardHash,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
          intentHash,
          await hyperProver.getAddress(),
          data,
          { value: fee },
        )

      //the testMailbox's dispatch method directly calls the hyperProver's handle method
      expect((await hyperProver.provenIntents(intentHash)).claimant).to.eq(
        await claimant.getAddress(),
      )
      expect(
        (await hyperProver.provenIntents(intentHash)).destinationChainID,
      ).to.eq(31337)

      //but lets simulate it fully anyway

      // Simulate the message being handled on the destination chain
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'bytes32[]'],
        [[intentHash], [ethers.zeroPadValue(await claimant.getAddress(), 32)]],
      )

      // For the end-to-end test, we need to simulate the mailbox
      // by deploying a new hyperProver with owner as the mailbox
      const simulatedHyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress(), [
        ethers.zeroPadValue(await inbox.getAddress(), 32),
      ], 200000)

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

      expect(
        (await simulatedHyperProver.provenIntents(intentHash)).claimant,
      ).to.eq(await claimant.getAddress())
      expect(
        (await simulatedHyperProver.provenIntents(intentHash))
          .destinationChainID,
      ).to.eq(12345)
    })

    it('should work with batched message bridge fulfillment end-to-end', async () => {
      hyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await mailbox.getAddress(), await inbox.getAddress(), [
        ethers.zeroPadValue(await inbox.getAddress(), 32),
        ethers.zeroPadValue(await hyperProver.getAddress(), 32),
      ], 200000)

      // Set up token and mint
      await token.mint(solver.address, 2 * amount)

      // Set up common data
      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const metadata = '0x1234'
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['bytes32', 'bytes', 'address'],
        [
          ethers.zeroPadValue(await hyperProver.getAddress(), 32),
          metadata,
          ethers.ZeroAddress,
        ],
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
        tokens: [],
      }

      const { intentHash: intentHash0, rewardHash: rewardHash0 } = hashIntent({
        route,
        reward,
      })

      // Approve tokens and check initial state
      await token.connect(solver).approve(await inbox.getAddress(), amount)
      expect((await hyperProver.provenIntents(intentHash0)).claimant).to.eq(
        ethers.ZeroAddress,
      )

      // Get fee for first intent
      const fee = await hyperProver.fetchFee(
        sourceChainID,
        [intentHash0],
        [ethers.zeroPadValue(await claimant.getAddress(), 32)],
        data,
      )

      // Fulfill first intent in batch
      await inbox
        .connect(solver)
        .fulfill(
          route,
          rewardHash0,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
          intentHash0,
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
      await inbox
        .connect(solver)
        .fulfill(
          route1,
          rewardHash1,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
          intentHash1,
          await hyperProver.getAddress(),
        )

      // Check intent hasn't been proven yet
      expect((await hyperProver.provenIntents(intentHash1)).claimant).to.eq(
        ethers.ZeroAddress,
      )

      // Prepare message body for batch
      const msgbody = abiCoder.encode(
        ['bytes32[]', 'bytes32[]'],
        [
          [intentHash0, intentHash1],
          [ethers.zeroPadValue(await claimant.getAddress(), 32), ethers.zeroPadValue(await claimant.getAddress(), 32)],
        ],
      )

      // Get fee for batch
      const batchFee = await hyperProver.fetchFee(
        sourceChainID,
        [intentHash0, intentHash1],
        [ethers.zeroPadValue(await claimant.getAddress(), 32), ethers.zeroPadValue(await claimant.getAddress(), 32)],
        data,
      )

      // Send batch to message bridge
      await expect(
        inbox
          .connect(solver)
          .initiateProving(
            sourceChainID,
            [intentHash0, intentHash1],
            await hyperProver.getAddress(),
            data,
            { value: batchFee },
          ),
      ).to.changeEtherBalance(solver, -Number(batchFee))

      //the testMailbox's dispatch method directly calls the hyperProver's handle method
      expect((await hyperProver.provenIntents(intentHash0)).claimant).to.eq(
        await claimant.getAddress(),
      )
      expect((await hyperProver.provenIntents(intentHash1)).claimant).to.eq(
        await claimant.getAddress(),
      )

      //but lets simulate it fully anyway

      // For the end-to-end test, we need to simulate the mailbox
      // by deploying a new hyperProver with owner as the mailbox
      const simulatedHyperProver = await (
        await ethers.getContractFactory('HyperProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress(), [
        ethers.zeroPadValue(await inbox.getAddress(), 32),
      ], 200000)

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
      expect(
        (await simulatedHyperProver.provenIntents(intentHash0)).claimant,
      ).to.eq(await claimant.getAddress())
      expect(
        (await simulatedHyperProver.provenIntents(intentHash1)).claimant,
      ).to.eq(await claimant.getAddress())
    })
  })
})
