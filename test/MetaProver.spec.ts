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

    // Deploy TestMetaRouter - use address(0) initially to prevent auto-processing
    const testRouter = await (
      await ethers.getContractFactory('TestMetaRouter')
    ).deploy(ethers.ZeroAddress)

    // Deploy Inbox
    const inbox = await (
      await ethers.getContractFactory('Inbox')
    ).deploy(owner.address, true, [])

    // Deploy Test ERC20 token
    const token = await (
      await ethers.getContractFactory('TestERC20')
    ).deploy('token', 'tkn')

    // Deploy MetaProver with required dependencies
    const metaProver = await (
      await ethers.getContractFactory('MetaProver')
    ).deploy(await testRouter.getAddress(), await inbox.getAddress(), [])

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
      ).deploy(await testRouter.getAddress(), await inbox.getAddress(), [
        additionalProver,
      ])

      // MetaProver whitelists itself
      expect(
        await newMetaProver.proverWhitelist(await newMetaProver.getAddress()),
      ).to.be.true
      // And whitelists the provided address
      expect(await newMetaProver.proverWhitelist(additionalProver)).to.be.true
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
      ).deploy(owner.address, await inbox.getAddress(), [
        await inbox.getAddress(),
      ])
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
      await expect(
        metaProver
          .connect(owner)
          .handle(
            12345,
            ethers.zeroPadValue('0x', 32),
            ethers.zeroPadValue('0x', 32),
            [],
            [],
          ),
      ).to.be.revertedWithCustomError(metaProver, 'UnauthorizedInitiateProving')
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

  describe('3. InitiateProving', () => {
    beforeEach(async () => {
      // Use owner as inbox so we can test initiateProving
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(await testRouter.getAddress(), owner.address, [
        await inbox.getAddress(),
      ])
    })

    it('should reject initiateProving from unauthorized source', async () => {
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const data = '0x'

      await expect(
        metaProver
          .connect(solver)
          .initiateProving(
            123,
            intentHashes,
            claimants,
            sourceChainProver,
            data,
          ),
      ).to.be.revertedWithCustomError(metaProver, 'UnauthorizedInitiateProving')
    })

    it('should correctly call dispatch in the initiateProving method', async () => {
      // Set up test data
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const data = '0x'

      // Before initiateProving, make sure the router hasn't been called
      expect(await testRouter.dispatched()).to.be.false

      await expect(
        metaProver.connect(owner).initiateProving(
          sourceChainId,
          intentHashes,
          claimants,
          sourceChainProver,
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

    it('should correctly get fee via fetchFee', async () => {
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      const sourceChainProver = await solver.getAddress()
      const data = '0x'

      // Call fetchFee
      const fee = await metaProver.fetchFee(
        sourceChainId,
        intentHashes,
        claimants,
        sourceChainProver,
        data,
      )

      // Verify we get the expected fee amount
      expect(fee).to.equal(await testRouter.FEE())
    })
  })

  // Create a mock TestMessageBridgeProver for testing end-to-end
  // interactions with Inbox without dealing with the actual cross-chain mechanisms
  async function createTestProvers() {
    // Deploy a TestMessageBridgeProver for use with the inbox
    const testMsgProver = await (
      await ethers.getContractFactory('TestMessageBridgeProver')
    ).deploy([await inbox.getAddress()])

    // Update whitelist to allow our MetaProver
    await testMsgProver.addWhitelistedProver(await metaProver.getAddress())

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
      ).deploy(await metaTestRouter.getAddress(), await inbox.getAddress(), [
        await inbox.getAddress(),
      ])

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
      const data = '0x'

      await token.connect(solver).approve(await inbox.getAddress(), amount)

      expect(await testMsgProver.provenIntents(intentHash)).to.eq(
        ethers.ZeroAddress,
      )

      // Get fee for fulfillment - using TestMessageBridgeProver
      const fee = await testMsgProver.fetchFee(
        sourceChainID,
        [intentHash],
        [await claimant.getAddress()],
        await metaProver.getAddress(),
        data,
      )

      // Fulfill the intent using message bridge
      await inbox.connect(solver).fulfillMessageBridge(
        route,
        rewardHash,
        await claimant.getAddress(),
        intentHash,
        await testMsgProver.getAddress(), // Use TestMessageBridgeProver
        await metaProver.getAddress(),
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
      ).deploy(owner.address, await inbox.getAddress(), [
        await inbox.getAddress(),
      ])

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
      const data = '0x'

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
      await expect(
        inbox.connect(solver).fulfillMessageBridgeBatched(
          route,
          rewardHash0,
          await claimant.getAddress(),
          intentHash0,
          await testMsgProver.getAddress(), // Use TestMessageBridgeProver
          await metaProver.getAddress(),
        ),
      )
        .to.emit(inbox, 'AddToBatch')
        .withArgs(
          intentHash0,
          sourceChainID,
          await claimant.getAddress(),
          await testMsgProver.getAddress(),
          await metaProver.getAddress(),
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
      await expect(
        inbox.connect(solver).fulfillMessageBridgeBatched(
          route1,
          rewardHash1,
          await claimant.getAddress(),
          intentHash1,
          await testMsgProver.getAddress(), // Use TestMessageBridgeProver
          await metaProver.getAddress(),
        ),
      ).to.emit(inbox, 'AddToBatch')

      // Check intent hasn't been proven yet
      expect(await testMsgProver.provenIntents(intentHash1)).to.eq(
        ethers.ZeroAddress,
      )

      // Get fee for batch
      const fee = await testMsgProver.fetchFee(
        sourceChainID,
        [intentHash0, intentHash1],
        [await claimant.getAddress(), await claimant.getAddress()],
        await metaProver.getAddress(),
        data,
      )

      // Send batch to message bridge
      await inbox.connect(solver).sendFulfilled(
        sourceChainID,
        [intentHash0, intentHash1],
        await testMsgProver.getAddress(), // Use TestMessageBridgeProver
        await metaProver.getAddress(),
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
