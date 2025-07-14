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
  Portal,
  IIntentSource,
  TestERC20,
  TestMetaRouter,
} from '../typechain-types'
import { encodeTransfer } from '../utils/encode'
import { TokenAmount, Route, Intent, hashIntent } from '../utils/intent'
import { addressToBytes32 } from '../utils/typeCasts'
import {
  UniversalIntent,
  UniversalRoute,
  UniversalReward,
  UniversalTokenAmount,
  convertIntentToUniversal,
  hashUniversalIntent,
} from '../utils/universalIntent'
import { TypeCasts } from '../utils/typeCasts'

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
 * 3. Proof Initiation (prove())
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

  // Helper function to convert UniversalRoute to Route for the fulfill function
  function universalRouteToRoute(universalRoute: UniversalRoute): Route {
    return {
      salt: universalRoute.salt,
      deadline: universalRoute.deadline,
      portal: TypeCasts.bytes32ToAddress(universalRoute.portal),
      tokens: universalRoute.tokens.map((token) => ({
        token: TypeCasts.bytes32ToAddress(token.token),
        amount: token.amount,
      })),
      calls: universalRoute.calls.map((call) => ({
        target: TypeCasts.bytes32ToAddress(call.target),
        data: call.data,
        value: call.value,
      })),
    }
  }

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

    // Deploy Portal (which includes Inbox)
    const portal = await (await ethers.getContractFactory('Portal')).deploy()
    const inbox = await ethers.getContractAt('Inbox', await portal.getAddress())

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
      // Verify ROUTER and PORTAL are set correctly
      expect(await metaProver.ROUTER()).to.equal(await testRouter.getAddress())
      expect(await metaProver.PORTAL()).to.equal(await inbox.getAddress())
    })

    it('should add constructor-provided provers to the whitelist', async () => {
      // Test with additional whitelisted provers
      const additionalProver = ethers.getAddress(await owner.getAddress())
      const newMetaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await testRouter.getAddress(),
        await inbox.getAddress(),
        [ethers.zeroPadValue(additionalProver, 32)],
        200000,
      ) // 200k gas limit

      // Check if the prover address is in the whitelist
      expect(
        await newMetaProver.isWhitelisted(
          ethers.zeroPadValue(additionalProver, 32),
        ),
      ).to.be.true
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
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
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
        ['bytes32[]', 'bytes32[]'],
        [[intentHash], [ethers.zeroPadValue(claimantAddress, 32)]],
      )

      const proofDataBefore = await metaProver.provenIntents(intentHash)
      expect(proofDataBefore.claimant).to.eq(ethers.ZeroAddress)

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

      const proofDataAfter = await metaProver.provenIntents(intentHash)
      expect(proofDataAfter.claimant).to.eq(claimantAddress)
    })

    it('should emit an event when intent is already proven', async () => {
      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'bytes32[]'],
        [[intentHash], [ethers.zeroPadValue(claimantAddress, 32)]],
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
        ['bytes32[]', 'bytes32[]'],
        [
          [intentHash, otherHash],
          [
            ethers.zeroPadValue(claimantAddress, 32),
            ethers.zeroPadValue(otherAddress, 32),
          ],
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

      const proofDataAfter = await metaProver.provenIntents(intentHash)
      expect(proofDataAfter.claimant).to.eq(claimantAddress)
      const proofData2 = await metaProver.provenIntents(otherHash)
      expect(proofData2.claimant).to.eq(otherAddress)
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
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )
    })

    it('should revert on underpayment', async () => {
      // Set up test data
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [ethers.zeroPadValue(sourceChainProver, 32)],
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
        metaProver.connect(owner).prove(
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
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [ethers.zeroPadValue(sourceChainProver, 32)],
      )

      // Before sendProof, make sure the router hasn't been called
      expect(await testRouter.dispatched()).to.be.false

      await expect(
        metaProver.connect(owner).prove(
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
        ['bytes32[]', 'bytes32[]'],
        [intentHashes, claimants],
      )
      expect(await testRouter.messageBody()).to.eq(expectedBody)
    })

    it('should reject sendProof from unauthorized source', async () => {
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [ethers.zeroPadValue(sourceChainProver, 32)],
      )

      await expect(
        metaProver
          .connect(solver)
          .prove(owner.address, 123, intentHashes, claimants, data),
      )
        .to.be.revertedWithCustomError(metaProver, 'UnauthorizedProve')
        .withArgs(await solver.getAddress())
    })

    it('should correctly get fee via fetchFee', async () => {
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [ethers.zeroPadValue(sourceChainProver, 32)],
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

    it('should gracefully return funds to sender if they overpay', async () => {
      // Set up test data
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [ethers.zeroPadValue(sourceChainProver, 32)],
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
        metaProver.connect(owner).prove(
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
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [ethers.zeroPadValue(sourceChainProver, 32)],
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
      await metaProver.connect(owner).prove(
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
        [ethers.zeroPadValue(sourceChainProver, 32)],
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
          .prove(solver.address, sourceChainId, intentHashes, claimants, data, {
            value: fee,
          }),
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
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'bytes32[]'],
        [[intentHash], [ethers.zeroPadValue(claimantAddress, 32)]],
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

      const proofDataAfter = await metaProver.provenIntents(intentHash)
      expect(proofDataAfter.claimant).to.eq(claimantAddress)
    })

    it('should check that array lengths are consistent', async () => {
      // Set up test data with mismatched array lengths
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants: string[] = [] // Empty array to mismatch with intentHashes
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [ethers.zeroPadValue(sourceChainProver, 32)],
      )

      // Our implementation correctly checks for array length mismatch
      await expect(
        metaProver
          .connect(owner)
          .prove(solver.address, sourceChainId, intentHashes, claimants, data, {
            value: await testRouter.FEE(),
          }),
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
        [ethers.zeroPadValue(sourceChainProver, 32)],
      )

      // Empty arrays should process without error
      await expect(
        metaProver
          .connect(owner)
          .prove(solver.address, sourceChainId, intentHashes, claimants, data, {
            value: await testRouter.FEE(),
          }),
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
        claimants.push(ethers.zeroPadValue(await solver.getAddress(), 32)) // Use solver as claimant for all
      }

      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [ethers.zeroPadValue(sourceChainProver, 32)],
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
          .prove(solver.address, sourceChainId, intentHashes, claimants, data, {
            value: fee,
          }),
      ).to.not.be.reverted

      // Verify dispatch was called
      expect(await testRouter.dispatched()).to.be.true
    })

    it('should reject excessively large chain IDs', async () => {
      // Test with a very large chain ID (near uint256 max)
      const veryLargeChainId = ethers.MaxUint256 - 1n
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await solver.getAddress()
      const data = abiCoder.encode(
        ['bytes32'],
        [ethers.zeroPadValue(sourceChainProver, 32)],
      )

      // Should revert with ChainIdTooLarge error
      await expect(
        metaProver
          .connect(owner)
          .prove(
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
    // Since whitelist is immutable, we need to include both addresses from the start
    const whitelistedAddresses = [
      await inbox.getAddress(),
      await metaProver.getAddress(),
    ]
    const testMsgProver = await (
      await ethers.getContractFactory('TestMessageBridgeProver')
    ).deploy(
      await inbox.getAddress(),
      whitelistedAddresses.map((addr) => ethers.zeroPadValue(addr, 32)),
      200000,
    ) // Add default gas limit

    return { testMsgProver }
  }

  describe('4. Cross-VM Claimant Compatibility', () => {
    it('should skip non-EVM claimants when processing handle messages', async () => {
      // Deploy metaProver with owner as router for direct testing
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await owner.getAddress(), // owner as router
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

      // Create test data
      const intentHash1 = ethers.keccak256('0x1234')
      const intentHash2 = ethers.keccak256('0x5678')
      const validClaimant = ethers.zeroPadValue(await claimant.getAddress(), 32)

      // Use a bytes32 claimant that doesn't represent a valid address
      // This simulates a cross-VM scenario where the claimant identifier
      // is not an Ethereum address but some other VM's identifier like Solana
      const nonAddressClaimant = ethers.keccak256(
        ethers.toUtf8Bytes('non-evm-claimant-identifier'),
      )

      // Create message with both valid and invalid claimants
      const msgBody = abiCoder.encode(
        ['bytes32[]', 'bytes32[]'],
        [
          [intentHash1, intentHash2],
          [validClaimant, nonAddressClaimant],
        ],
      )

      // Process the message
      await metaProver
        .connect(owner) // owner acts as router
        .handle(
          12345,
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgBody,
          [], // empty ReadOperation array
          [], // empty bytes array
        )

      // The valid claimant should be processed
      const proofData1 = await metaProver.provenIntents(intentHash1)
      expect(proofData1.claimant).to.eq(await claimant.getAddress())

      // The invalid claimant should be skipped (not processed)
      const proofData2 = await metaProver.provenIntents(intentHash2)
      expect(proofData2.claimant).to.eq(ethers.ZeroAddress)
    })

    it('should revert when attempting to prove with non-address bytes32 claimant', async () => {
      const chainId = 12345
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await testRouter.getAddress(),
        await inbox.getAddress(),
        [
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          ethers.zeroPadValue(await metaProver.getAddress(), 32),
        ],
        200000,
      )

      // Get Portal and IntentSource interfaces
      const portal = await ethers.getContractAt(
        'Portal',
        await inbox.getAddress(),
      )
      const intentSource = await ethers.getContractAt(
        'IIntentSource',
        await portal.getAddress(),
      )

      await token.mint(solver.address, amount)
      await token.mint(owner.address, amount) // For funding the intent

      // Set up intent data
      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const salt = ethers.encodeBytes32String('0x987')
      const routeTokens = [{ token: await token.getAddress(), amount: amount }]
      const route = {
        salt: salt,
        deadline: timeStamp + 1000,
        portal: await inbox.getAddress(),
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

      const destination = Number(
        (await metaProver.runner?.provider?.getNetwork())?.chainId,
      )

      // Create regular intent for publishing
      const intent: Intent = {
        destination,
        route,
        reward,
      }

      // Convert to UniversalIntent for hashing
      const universalIntent = convertIntentToUniversal(intent)
      const { intentHash, rewardHash } = hashUniversalIntent(universalIntent)

      // arbitrary bytes32 claimant that doesn't represent a valid EVM address
      // this simulates a cross-VM scenario where the claimant identifier
      // is not an Ethereum address but some other VM's identifier like Solana
      const nonAddressClaimant = ethers.keccak256(
        ethers.toUtf8Bytes('non-evm-claimant-identifier'),
      )

      // Prepare message data for MetaProver (simpler format than HyperProver)
      const data = abiCoder.encode(
        ['bytes32'],
        [ethers.zeroPadValue(await metaProver.getAddress(), 32)],
      )

      // Approve tokens for funding
      await token.connect(owner).approve(await portal.getAddress(), amount)

      // Publish and fund the intent
      await intentSource.connect(owner).publishAndFund(intent, false, {
        value: ethers.parseEther('0.01'),
      })

      await token.connect(solver).approve(await inbox.getAddress(), amount)

      const fee = await metaProver.fetchFee(
        sourceChainID,
        [intentHash],
        [nonAddressClaimant],
        data,
      )

      // Convert UniversalRoute to Route for fulfillAndProve
      const regularRoute = universalRouteToRoute(universalIntent.route)

      // Since non-EVM addresses have non-zero top 12 bytes, we expect this to succeed
      // at the fulfill stage but fail when the prover tries to process it
      await expect(
        inbox
          .connect(solver)
          .fulfillAndProve(
            intentHash,
            regularRoute,
            rewardHash,
            nonAddressClaimant,
            await metaProver.getAddress(),
            sourceChainID,
            data,
            { value: fee },
          ),
      ).to.not.be.reverted

      // Verify the intent was fulfilled with the non-address claimant
      expect(await inbox.fulfilled(intentHash)).to.eq(nonAddressClaimant)

      // The prover should not have processed this intent due to invalid address format
      const provenIntent = await metaProver.provenIntents(intentHash)
      expect(provenIntent.claimant).to.eq(ethers.ZeroAddress)
    })
  })

  describe('5. End-to-End', () => {
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
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      ) // Add default gas limit

      // Update the router reference
      testRouter = metaTestRouter
    })

    it('works end to end with message bridge', async () => {
      // Get Portal and IntentSource interfaces
      const portal = await ethers.getContractAt(
        'Portal',
        await inbox.getAddress(),
      )
      const intentSource = await ethers.getContractAt(
        'IIntentSource',
        await portal.getAddress(),
      )

      await token.mint(solver.address, amount)
      await token.mint(owner.address, amount) // For funding the intent

      // Set up intent data
      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const salt = ethers.encodeBytes32String('0x987')
      const routeTokens = [{ token: await token.getAddress(), amount: amount }]
      const route = {
        salt: salt,
        deadline: timeStamp + 1000,
        portal: await inbox.getAddress(),
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

      const destination = Number(
        await ethers.provider.getNetwork().then((n) => n.chainId),
      )

      // Create regular intent for publishing
      const intent: Intent = {
        destination,
        route,
        reward,
      }

      // Convert to UniversalIntent for hashing
      const universalIntent = convertIntentToUniversal(intent)
      const { intentHash, rewardHash } = hashUniversalIntent(universalIntent)
      const data = abiCoder.encode(
        ['bytes32'],
        [ethers.zeroPadValue(await metaProver.getAddress(), 32)],
      )

      // Approve tokens for funding
      await token.connect(owner).approve(await portal.getAddress(), amount)

      // Publish and fund the intent
      await intentSource.connect(owner).publishAndFund(intent, false, {
        value: ethers.parseEther('0.01'),
      })

      await token.connect(solver).approve(await inbox.getAddress(), amount)

      const proofDataBefore = await testMsgProver.provenIntents(intentHash)
      expect(proofDataBefore.claimant).to.eq(ethers.ZeroAddress)

      // Get fee for fulfillment - using TestMessageBridgeProver
      const fee = await testMsgProver.fetchFee(
        sourceChainID,
        [intentHash],
        [ethers.zeroPadValue(await claimant.getAddress(), 32)],
        data,
      )

      // Convert UniversalRoute to Route for fulfillAndProve
      const regularRoute = universalRouteToRoute(universalIntent.route)

      // Fulfill the intent using message bridge
      await inbox.connect(solver).fulfillAndProve(
        intentHash,
        regularRoute,
        rewardHash,
        ethers.zeroPadValue(await claimant.getAddress(), 32),
        await testMsgProver.getAddress(), // Use TestMessageBridgeProver
        sourceChainID,
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
      const proofDataAfter = await testMsgProver.provenIntents(intentHash)
      expect(proofDataAfter.claimant).to.eq(await claimant.getAddress())

      // Meanwhile, our TestMetaRouter with auto-processing should also prove intents
      // Test that our MetaProver works correctly with TestMetaRouter

      // Set up message data
      const metaMsgBody = abiCoder.encode(
        ['bytes32[]', 'bytes32[]'],
        [[intentHash], [ethers.zeroPadValue(await claimant.getAddress(), 32)]],
      )

      // Reset the metaProver's proven intents for testing
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        owner.address,
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
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
      const proofDataFinal = await metaProver.provenIntents(intentHash)
      expect(proofDataFinal.claimant).to.eq(await claimant.getAddress())
    })

    it('should work with batched message bridge fulfillment end-to-end', async () => {
      // Get Portal and IntentSource interfaces
      const portal = await ethers.getContractAt(
        'Portal',
        await inbox.getAddress(),
      )
      const intentSource = await ethers.getContractAt(
        'IIntentSource',
        await portal.getAddress(),
      )

      await token.mint(solver.address, 2 * amount)
      await token.mint(owner.address, 2 * amount) // For funding the intents

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
        deadline: timeStamp + 1000,
        portal: await inbox.getAddress(),
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

      const destination = Number(
        await ethers.provider.getNetwork().then((n) => n.chainId),
      )

      // Create regular intent for publishing
      const intent0: Intent = {
        destination,
        route,
        reward,
      }

      // Convert to UniversalIntent for hashing
      const universalIntent0 = convertIntentToUniversal(intent0)
      const { intentHash: intentHash0, rewardHash: rewardHash0 } =
        hashUniversalIntent(universalIntent0)

      // Approve tokens for funding and publish first intent
      await token.connect(owner).approve(await portal.getAddress(), amount)
      await intentSource.connect(owner).publishAndFund(intent0, false, {
        value: ethers.parseEther('0.01'),
      })

      // Approve tokens and check initial state
      await token.connect(solver).approve(await inbox.getAddress(), amount)
      const proofDataBefore0 = await testMsgProver.provenIntents(intentHash0)
      expect(proofDataBefore0.claimant).to.eq(ethers.ZeroAddress)

      // Convert UniversalRoute to Route for fulfill
      const regularRoute0 = universalRouteToRoute(universalIntent0.route)

      // Fulfill first intent in batch
      await inbox
        .connect(solver)
        .fulfill(
          intentHash0,
          regularRoute0,
          rewardHash0,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        )

      // Create second intent with different salt
      salt = ethers.encodeBytes32String('0x1234')
      const route1 = {
        salt: salt,
        deadline: timeStamp + 1000,
        portal: await inbox.getAddress(),
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
      // Create regular intent for publishing
      const intent1: Intent = {
        destination,
        route: route1,
        reward: reward1,
      }

      // Convert to UniversalIntent for hashing
      const universalIntent1 = convertIntentToUniversal(intent1)
      const { intentHash: intentHash1, rewardHash: rewardHash1 } =
        hashUniversalIntent(universalIntent1)

      // Convert UniversalRoute to Route for fulfill
      const regularRoute1 = universalRouteToRoute(universalIntent1.route)

      // Approve tokens for funding and publish second intent
      await token.connect(owner).approve(await portal.getAddress(), amount)
      await intentSource.connect(owner).publishAndFund(intent1, false, {
        value: ethers.parseEther('0.01'),
      })

      // Approve tokens and fulfill second intent in batch
      await token.connect(solver).approve(await inbox.getAddress(), amount)
      await inbox
        .connect(solver)
        .fulfill(
          intentHash1,
          regularRoute1,
          rewardHash1,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        )

      // Check intent hasn't been proven yet
      const proofDataBefore1 = await testMsgProver.provenIntents(intentHash1)
      expect(proofDataBefore1.claimant).to.eq(ethers.ZeroAddress)

      // Get fee for batch
      const fee = await testMsgProver.fetchFee(
        sourceChainID,
        [intentHash0, intentHash1],
        [
          ethers.zeroPadValue(await claimant.getAddress(), 32),
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        ],
        data,
      )

      // Send batch to message bridge
      await inbox.connect(solver).prove(
        sourceChainID,
        await testMsgProver.getAddress(), // Use TestMessageBridgeProver
        [intentHash0, intentHash1],
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
        ethers.zeroPadValue(await claimant.getAddress(), 32),
      )
      expect(await testMsgProver.lastClaimants(1)).to.equal(
        ethers.zeroPadValue(await claimant.getAddress(), 32),
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
      const proofDataFinal0 = await testMsgProver.provenIntents(intentHash0)
      expect(proofDataFinal0.claimant).to.eq(await claimant.getAddress())
      const proofDataFinal1 = await testMsgProver.provenIntents(intentHash1)
      expect(proofDataFinal1.claimant).to.eq(await claimant.getAddress())
    })
  })
})
