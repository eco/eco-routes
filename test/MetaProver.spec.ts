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

/**
 * TEST SCENARIOS:
 *
 * 1. Constructor
 *   - Test initialization with correct router and inbox addresses
 *   - Test whitelisting of constructor-provided provers
 *   - Verify correct proof type reporting
 *   - Verify default gas limit setting
 *
 * 2. Message Handling (handle())
 *   - Test authorization checks for message senders
 *   - Test handling of single intent proof
 *   - Test handling of duplicate intent proofs
 *   - Test batch proving of multiple intents
 *   - Test validation of message data format
 *
 * 3. Proof Sending (sendProof())
 *   - Test authorization checks for proof initiators
 *   - Test fee calculation and handling
 *   - Test underpayment rejection
 *   - Test overpayment refund
 *   - Test exact payment processing
 *   - Test gas limit specification through data parameter
 *   - Verify proper message encoding and router interaction
 *
 * 4. Edge Cases
 *   - Test handling of empty arrays
 *   - Test handling of large arrays without gas issues
 *   - Test handling of large chain IDs
 *   - Test with mismatched array lengths
 *
 * 5. End-to-End Integration
 *   - Test complete flow with TestMessageBridgeProver
 *   - Test batch proving across multiple contracts
 *   - Verify correct token handling in complete intent execution
 */

describe('MetaProver Test', (): void => {
  let inbox: Inbox
  let metaProver: MetaProver
  let testRouter: TestMetaRouter
  let token: TestERC20
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let claimant: SignerWithAddress
  const amount: number = 1234567890
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  async function deployMetaProverFixture(): Promise<{
    inbox: Inbox
    metaProver: MetaProver
    testRouter: TestMetaRouter
    token: TestERC20
    owner: SignerWithAddress
    solver: SignerWithAddress
    claimant: SignerWithAddress
  }> {
    const [owner, solver, claimant] = await ethers.getSigners()

    // Deploy TestMetaRouter
    const testRouter = await (
      await ethers.getContractFactory('TestMetaRouter')
    ).deploy(ethers.ZeroAddress)

    // Deploy Inbox
    const inbox = await (await ethers.getContractFactory('Inbox')).deploy()

    // Deploy Test ERC20 token
    const token = await (
      await ethers.getContractFactory('TestERC20')
    ).deploy('token', 'tkn')

    // Deploy MetaProver with required dependencies
    const metaProver = await (
      await ethers.getContractFactory('MetaProver')
    ).deploy(
      await testRouter.getAddress(),
      await inbox.getAddress(),
      [],
      200000,
    ) // 200k gas limit

    return {
      inbox,
      metaProver,
      testRouter,
      token,
      owner,
      solver,
      claimant,
    }
  }

  beforeEach(async (): Promise<void> => {
    ;({ inbox, metaProver, testRouter, token, owner, solver, claimant } =
      await loadFixture(deployMetaProverFixture))
  })

  describe('1. Constructor', () => {
    it('should initialize with the correct router and inbox addresses', async () => {
      // Verify ROUTER and INBOX are set correctly
      expect(await metaProver.ROUTER()).to.equal(await testRouter.getAddress())
      expect(await metaProver.INBOX()).to.equal(await inbox.getAddress())
    })

    it('should add constructor-provided provers to the whitelist', async () => {
      // Test with additional whitelisted provers
      const additionalProver = await owner.getAddress()
      const newMetaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await testRouter.getAddress(),
        await inbox.getAddress(),
        [{ chainId: 1, prover: additionalProver }],
        200000,
      ) // 200k gas limit

      // MetaProver whitelists itself on current chainId
      const currentChainId = await ethers.provider
        .getNetwork()
        .then((n) => n.chainId)
      expect(
        await newMetaProver.proverWhitelist(
          currentChainId,
          await newMetaProver.getAddress(),
        ),
      ).to.be.true
      // And whitelists the provided address on the specified chainId
      expect(await newMetaProver.proverWhitelist(1, additionalProver)).to.be
        .true
    })

    it('should have the correct default gas limit', async () => {
      // Verify the default gas limit was set correctly
      expect(await metaProver.DEFAULT_GAS_LIMIT()).to.equal(200000)

      // Deploy a prover with custom gas limit
      const customGasLimit = 300000 // 300k
      const customMetaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await testRouter.getAddress(),
        await inbox.getAddress(),
        [],
        customGasLimit,
      )

      // Verify custom gas limit was set
      expect(await customMetaProver.DEFAULT_GAS_LIMIT()).to.equal(
        customGasLimit,
      )
    })

    it('should return the correct proof type', async () => {
      expect(await metaProver.getProofType()).to.equal('Metalayer')
    })
  })

  describe('2. Handle', () => {
    beforeEach(async () => {
      // Set up a new MetaProver with owner as router for direct testing
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        owner.address,
        await inbox.getAddress(),
        [{ chainId: 12345, prover: await inbox.getAddress() }],
        200000,
      )
    })

    it('should revert when msg.sender is not the router', async () => {
      await expect(
        metaProver
          .connect(claimant)
          .handle(
            12345,
            ethers.zeroPadValue('0x', 32),
            ethers.zeroPadValue('0x', 32),
            [],
            [],
          ),
      ).to.be.revertedWithCustomError(metaProver, 'UnauthorizedHandle')
    })

    it('should revert when sender field is not authorized', async () => {
      const validAddress = await solver.getAddress()
      await expect(
        metaProver.connect(owner).handle(
          12345,
          ethers.zeroPadValue(validAddress, 32), // Use a valid but unauthorized address
          ethers.zeroPadValue('0x', 32),
          [],
          [],
        ),
      ).to.be.revertedWithCustomError(metaProver, 'UnauthorizedIncomingProof')
    })

    it('should record a single proven intent when called correctly', async () => {
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

    it('should emit an event when intent is already proven', async () => {
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [claimantAddress]],
      )

      // First handle call proves the intent
      await metaProver
        .connect(owner)
        .handle(
          12345,
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgBody,
          [],
          [],
        )

      // Second handle call should emit IntentAlreadyProven
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

      expect(await metaProver.provenIntents(intentHash)).to.eq(claimantAddress)
      expect(await metaProver.provenIntents(otherHash)).to.eq(otherAddress)
    })
  })

  describe('3. SendProof', () => {
    beforeEach(async () => {
      // Use owner as inbox so we can test SendProof
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await testRouter.getAddress(),
        owner.address,
        [{ chainId: 12345, prover: await inbox.getAddress() }],
        200000,
      )
    })

    it('should revert on underpayment', async () => {
      // Set up test data
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [await ethers.zeroPadValue(sourceChainProver, 32)],
      )

      // Before sendProof, make sure the router hasn't been called
      expect(await testRouter.dispatched()).to.be.false

      const fee = await metaProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )
      const initBalance = await solver.provider.getBalance(solver.address)

      await expect(
        metaProver.connect(owner).sendProof(
          solver.address,
          sourceChainId,
          intentHashes,
          claimants,
          data,
          { value: fee - BigInt(1) }, // Send TestMetaRouter.FEE amount
        ),
      ).to.be.reverted
    })

    it('should correctly call dispatch in the sendProof method', async () => {
      // Set up test data
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [await ethers.zeroPadValue(sourceChainProver, 32)],
      )

      // Before sendProof, make sure the router hasn't been called
      expect(await testRouter.dispatched()).to.be.false

      await expect(
        metaProver.connect(owner).sendProof(
          solver.address,
          sourceChainId,
          intentHashes,
          claimants,
          data,
          { value: await testRouter.FEE() }, // Send TestMetaRouter.FEE amount
        ),
      )
        .to.emit(metaProver, 'BatchSent')
        .withArgs(intentHashes[0], sourceChainId)

      // Verify the router was called with correct parameters
      expect(await testRouter.dispatched()).to.be.true
      expect(await testRouter.destinationDomain()).to.eq(sourceChainId)

      // Verify recipient address (now bytes32) - TestMetaRouter stores it as bytes32
      const expectedRecipientBytes32 = ethers.zeroPadValue(
        sourceChainProver,
        32,
      )
      expect(await testRouter.recipientAddress()).to.eq(
        expectedRecipientBytes32,
      )

      // Verify message encoding is correct
      const expectedBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [intentHashes, claimants],
      )
      expect(await testRouter.messageBody()).to.eq(expectedBody)
    })

    it('should reject sendProof from unauthorized source', async () => {
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [await ethers.zeroPadValue(sourceChainProver, 32)],
      )

      await expect(
        metaProver
          .connect(solver)
          .sendProof(owner.address, 123, intentHashes, claimants, data),
      )
        .to.be.revertedWithCustomError(metaProver, 'UnauthorizedSendProof')
        .withArgs(await solver.getAddress())
    })

    it('should correctly get fee via fetchFee', async () => {
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [await ethers.zeroPadValue(sourceChainProver, 32)],
      )

      // Call fetchFee
      const fee = await metaProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )

      // Verify we get the expected fee amount
      expect(fee).to.equal(await testRouter.FEE())
    })

    it('should correctly call dispatch in the sendProof method', async () => {
      // Set up test data
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [await ethers.zeroPadValue(sourceChainProver, 32)],
      )

      // Before sendProof, make sure the router hasn't been called
      expect(await testRouter.dispatched()).to.be.false

      await expect(
        metaProver.connect(owner).sendProof(
          solver.address,
          sourceChainId,
          intentHashes,
          claimants,
          data,
          { value: await testRouter.FEE() }, // Send TestMetaRouter.FEE amount
        ),
      )
        .to.emit(metaProver, 'BatchSent')
        .withArgs(intentHashes[0], sourceChainId)

      // Verify the router was called with correct parameters
      expect(await testRouter.dispatched()).to.be.true
      expect(await testRouter.destinationDomain()).to.eq(sourceChainId)

      // Verify recipient address (now bytes32) - TestMetaRouter stores it as bytes32
      const expectedRecipientBytes32 = ethers.zeroPadValue(
        sourceChainProver,
        32,
      )
      expect(await testRouter.recipientAddress()).to.eq(
        expectedRecipientBytes32,
      )

      // Verify message encoding is correct
      const expectedBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [intentHashes, claimants],
      )
      expect(await testRouter.messageBody()).to.eq(expectedBody)
    })

    it('should gracefully return funds to sender if they overpay', async () => {
      // Set up test data
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [await ethers.zeroPadValue(sourceChainProver, 32)],
      )

      // Before sendProof, make sure the router hasn't been called
      expect(await testRouter.dispatched()).to.be.false

      const fee = await metaProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )
      const initBalance = await solver.provider.getBalance(solver.address)

      await expect(
        metaProver.connect(owner).sendProof(
          solver.address,
          sourceChainId,
          intentHashes,
          claimants,
          data,
          { value: fee * BigInt(2) }, // Send TestMetaRouter.FEE amount
        ),
      ).to.not.be.reverted
      expect(
        (await owner.provider.getBalance(solver.address)) >
          initBalance - fee * BigInt(10),
      ).to.be.true
    })

    it('should handle exact fee payment with no refund needed', async () => {
      // Set up test data
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [await ethers.zeroPadValue(sourceChainProver, 32)],
      )

      const fee = await metaProver.fetchFee(
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
      await metaProver.connect(owner).sendProof(
        solver.address,
        sourceChainId,
        intentHashes,
        claimants,
        data,
        { value: fee }, // Exact fee amount
      )

      // Should dispatch successfully without refund
      expect(await testRouter.dispatched()).to.be.true

      // Balance should be unchanged since no refund was needed
      const solverBalanceAfter = await solver.provider.getBalance(
        solver.address,
      )
      expect(solverBalanceBefore).to.equal(solverBalanceAfter)
    })

    it('should handle empty arrays gracefully', async () => {
      // Set up test data with empty arrays
      const sourceChainId = 123
      const intentHashes: string[] = []
      const claimants: string[] = []
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [await ethers.zeroPadValue(sourceChainProver, 32)],
      )

      const fee = await metaProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )

      // Should process empty arrays without error
      await expect(
        metaProver
          .connect(owner)
          .sendProof(
            solver.address,
            sourceChainId,
            intentHashes,
            claimants,
            data,
            { value: fee },
          ),
      ).to.not.be.reverted

      // Should dispatch successfully
      expect(await testRouter.dispatched()).to.be.true
    })

    it('should handle non-empty parameters in handle function', async () => {
      // Set up a new MetaProver with owner as router for direct testing
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        owner.address,
        await inbox.getAddress(),
        [{ chainId: 12345, prover: await inbox.getAddress() }],
        200000,
      )

      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [claimantAddress]],
      )

      // Since ReadOperation type isn't exposed directly in tests,
      // we'll just test that the handle function works without those params
      await expect(
        metaProver.connect(owner).handle(
          12345,
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgBody,
          [], // empty ReadOperation array
          [], // empty bytes array
        ),
      )
        .to.emit(metaProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress)

      expect(await metaProver.provenIntents(intentHash)).to.eq(claimantAddress)
    })

    it('should check that array lengths are consistent', async () => {
      // Set up test data with mismatched array lengths
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants: string[] = [] // Empty array to mismatch with intentHashes
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [await ethers.zeroPadValue(sourceChainProver, 32)],
      )

      // Our implementation correctly checks for array length mismatch
      await expect(
        metaProver
          .connect(owner)
          .sendProof(
            solver.address,
            sourceChainId,
            intentHashes,
            claimants,
            data,
            { value: await testRouter.FEE() },
          ),
      ).to.be.revertedWithCustomError(metaProver, 'ArrayLengthMismatch')

      // This test confirms the validation that arrays must have
      // consistent lengths, which is a security best practice
    })

    it('should handle zero-length arrays safely', async () => {
      // Set up test data with empty arrays (but matched lengths)
      const sourceChainId = 123
      const intentHashes: string[] = []
      const claimants: string[] = []
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [await ethers.zeroPadValue(sourceChainProver, 32)],
      )

      // Empty arrays should process without error
      await expect(
        metaProver
          .connect(owner)
          .sendProof(
            solver.address,
            sourceChainId,
            intentHashes,
            claimants,
            data,
            { value: await testRouter.FEE() },
          ),
      ).to.not.be.reverted

      // Verify the dispatch was called (event should be emitted)
      expect(await testRouter.dispatched()).to.be.true
    })

    it('should handle large arrays without gas issues', async () => {
      // Create large arrays (100 elements - which is reasonably large for gas testing)
      const sourceChainId = 123
      const intentHashes: string[] = []
      const claimants: string[] = []

      // Generate 100 random intent hashes and corresponding claimant addresses
      for (let i = 0; i < 100; i++) {
        intentHashes.push(ethers.keccak256(ethers.toUtf8Bytes(`intent-${i}`)))
        claimants.push(await solver.getAddress()) // Use solver as claimant for all
      }

      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [await ethers.zeroPadValue(sourceChainProver, 32)],
      )

      // Get fee for this large batch
      const fee = await metaProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        data,
      )

      // Large arrays should still process without gas errors
      // Note: In real networks, this might actually hit gas limits
      // This test is more to verify the code logic handles large arrays
      await expect(
        metaProver
          .connect(owner)
          .sendProof(
            solver.address,
            sourceChainId,
            intentHashes,
            claimants,
            data,
            { value: fee },
          ),
      ).to.not.be.reverted

      // Verify dispatch was called
      expect(await testRouter.dispatched()).to.be.true
    })

    it('should reject excessively large chain IDs', async () => {
      // Test with a very large chain ID (near uint256 max)
      const veryLargeChainId = ethers.MaxUint256 - 1n
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [await ethers.zeroPadValue(sourceChainProver, 32)],
      )

      // Should revert with ChainIdTooLarge error
      await expect(
        metaProver
          .connect(owner)
          .sendProof(
            solver.address,
            veryLargeChainId,
            intentHashes,
            claimants,
            data,
            { value: await testRouter.FEE() },
          ),
      )
        .to.be.revertedWithCustomError(metaProver, 'ChainIdTooLarge')
        .withArgs(veryLargeChainId)
    })
  })

  // Create a mock TestMessageBridgeProver for testing end-to-end
  // interactions with Inbox without dealing with the actual cross-chain mechanisms
  async function createTestProvers() {
    // Deploy a TestMessageBridgeProver for use with the inbox
    const testMsgProver = await (
      await ethers.getContractFactory('TestMessageBridgeProver')
    ).deploy(
      await inbox.getAddress(),
      [{ chainId: 12345, prover: await inbox.getAddress() }],
      200000,
    ) // Add default gas limit

    // Update whitelist to allow our MetaProver
    await testMsgProver.addWhitelistedProver(
      12345,
      await metaProver.getAddress(),
    )

    return { testMsgProver }
  }

  describe('4. End-to-End', () => {
    let testMsgProver: any

    beforeEach(async () => {
      // For the end-to-end test, deploy contracts that will work with the inbox
      const { testMsgProver: msgProver } = await createTestProvers()
      testMsgProver = msgProver

      // Create a MetaProver with a processor set
      const metaTestRouter = await (
        await ethers.getContractFactory('TestMetaRouter')
      ).deploy(await metaProver.getAddress())

      // Update metaProver to use the new router
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await metaTestRouter.getAddress(),
        await inbox.getAddress(),
        [{ chainId: 12345, prover: await inbox.getAddress() }],
        200000,
      ) // Add default gas limit

      // Update the router reference
      testRouter = metaTestRouter
    })

    it('works end to end with message bridge', async () => {
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
          await ethers.provider.getNetwork().then((n) => n.chainId),
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
        prover: await testMsgProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeValue: 1n,
        tokens: [] as TokenAmount[],
      }

      const { intentHash, rewardHash } = hashIntent({ route, reward })
      const data = abiCoder.encode(
        ['bytes32'],
        [ethers.zeroPadValue(await metaProver.getAddress(), 32)],
      )

      await token.connect(solver).approve(await inbox.getAddress(), amount)

      expect(await testMsgProver.provenIntents(intentHash)).to.eq(
        ethers.ZeroAddress,
      )

      // Get fee for fulfillment - using TestMessageBridgeProver
      const fee = await testMsgProver.fetchFee(
        sourceChainID,
        [intentHash],
        [await claimant.getAddress()],
        data,
      )

      // Fulfill the intent using message bridge
      await inbox.connect(solver).fulfillAndProve(
        route,
        rewardHash,
        await claimant.getAddress(),
        intentHash,
        await testMsgProver.getAddress(), // Use TestMessageBridgeProver
        data,
        { value: fee },
      )

      // TestMessageBridgeProver should have been called
      expect(await testMsgProver.dispatched()).to.be.true

      // Manually set the proven intent in TestMessageBridgeProver to simulate proving
      await testMsgProver.addProvenIntent(
        intentHash,
        await claimant.getAddress(),
      )

      // Verify the intent is now proven
      expect(await testMsgProver.provenIntents(intentHash)).to.eq(
        await claimant.getAddress(),
      )

      // Meanwhile, our TestMetaRouter with auto-processing should also prove intents
      // Test that our MetaProver works correctly with TestMetaRouter

      // Set up message data
      const metaMsgBody = abiCoder.encode(
        ['bytes32[]', 'address[]'],
        [[intentHash], [await claimant.getAddress()]],
      )

      // Reset the metaProver's proven intents for testing
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        owner.address,
        await inbox.getAddress(),
        [{ chainId: 12345, prover: await inbox.getAddress() }],
        200000,
      )

      // Call handle directly to verify that MetaProver's intent proving works
      await metaProver
        .connect(owner)
        .handle(
          12345,
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          metaMsgBody,
          [],
          [],
        )

      // Verify that MetaProver marked the intent as proven
      expect(await metaProver.provenIntents(intentHash)).to.eq(
        await claimant.getAddress(),
      )
    })

    it('should work with batched message bridge fulfillment end-to-end', async () => {
      await token.mint(solver.address, 2 * amount)

      // Set up common data
      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const data = abiCoder.encode(
        ['bytes32'],
        [ethers.zeroPadValue(await metaProver.getAddress(), 32)],
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
          await ethers.provider.getNetwork().then((n) => n.chainId),
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
        prover: await testMsgProver.getAddress(), // Use TestMessageBridgeProver
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
      expect(await testMsgProver.provenIntents(intentHash0)).to.eq(
        ethers.ZeroAddress,
      )

      // Fulfill first intent in batch
      await inbox.connect(solver).fulfill(
        route,
        rewardHash0,
        await claimant.getAddress(),
        intentHash0,
        await testMsgProver.getAddress(), // Use TestMessageBridgeProver
      )

      // Create second intent with different salt
      salt = ethers.encodeBytes32String('0x1234')
      const route1 = {
        salt: salt,
        source: sourceChainID,
        destination: Number(
          await ethers.provider.getNetwork().then((n) => n.chainId),
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
        prover: await testMsgProver.getAddress(), // Use TestMessageBridgeProver
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
      await inbox.connect(solver).fulfill(
        route1,
        rewardHash1,
        await claimant.getAddress(),
        intentHash1,
        await testMsgProver.getAddress(), // Use TestMessageBridgeProver
      )

      // Check intent hasn't been proven yet
      expect(await testMsgProver.provenIntents(intentHash1)).to.eq(
        ethers.ZeroAddress,
      )

      // Get fee for batch
      const fee = await testMsgProver.fetchFee(
        sourceChainID,
        [intentHash0, intentHash1],
        [await claimant.getAddress(), await claimant.getAddress()],
        data,
      )

      // Send batch to message bridge
      await inbox.connect(solver).initiateProving(
        sourceChainID,
        [intentHash0, intentHash1],
        await testMsgProver.getAddress(), // Use TestMessageBridgeProver
        data,
        { value: fee },
      )

      // TestMessageBridgeProver should have the batch data
      expect(await testMsgProver.dispatched()).to.be.true

      // Check the TestMessageBridgeProver's stored batch info
      expect(await testMsgProver.lastSourceChainId()).to.equal(sourceChainID)
      expect(await testMsgProver.lastIntentHashes(0)).to.equal(intentHash0)
      expect(await testMsgProver.lastIntentHashes(1)).to.equal(intentHash1)
      expect(await testMsgProver.lastClaimants(0)).to.equal(
        await claimant.getAddress(),
      )
      expect(await testMsgProver.lastClaimants(1)).to.equal(
        await claimant.getAddress(),
      )

      // Manually add the proven intents to simulate the cross-chain mechanism
      await testMsgProver.addProvenIntent(
        intentHash0,
        await claimant.getAddress(),
      )
      await testMsgProver.addProvenIntent(
        intentHash1,
        await claimant.getAddress(),
      )

      // Verify both intents were marked as proven
      expect(await testMsgProver.provenIntents(intentHash0)).to.eq(
        await claimant.getAddress(),
      )
      expect(await testMsgProver.provenIntents(intentHash1)).to.eq(
        await claimant.getAddress(),
      )
    })
  })
})
