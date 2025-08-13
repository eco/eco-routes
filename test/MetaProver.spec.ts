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
import { addressToBytes32, TypeCasts } from '../utils/typeCasts'

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
 *   - Test batch proof submission
 *   - Test cross-chain prover configuration
 *
 * 4. Cross-VM Claimant Compatibility
 *   - Test handling of non-EVM claimants in message processing
 *   - Test handling of invalid address formats
 *   - Test skipping of non-convertible addresses
 *   - Test processing of valid EVM addresses only
 *
 * 5. End-to-End Integration
 *   - Test complete flow from intent creation to proof verification
 *   - Test integration with Meta Router for cross-chain messaging
 *   - Test batch intent processing end-to-end
 *   - Test fee collection and distribution
 */

describe('MetaProver Test', (): void => {
  let inbox: Inbox
  let router: TestMetaRouter
  let metaProver: MetaProver
  let token: TestERC20
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let claimant: SignerWithAddress
  const amount: number = 1234567890
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  // Helper function to encode message body with chain ID prefix for handle
  function encodeMessageBody(
    intentHashes: string[],
    claimants: string[],
    chainId: number = 12345,
  ): string {
    const parts: string[] = []
    for (let i = 0; i < intentHashes.length; i++) {
      // If claimant is already 32 bytes (66 chars with 0x), use as is
      // Otherwise, pad it
      const claimantBytes =
        claimants[i].length === 66
          ? claimants[i]
          : ethers.zeroPadValue(claimants[i], 32)
      parts.push(intentHashes[i])
      parts.push(claimantBytes)
    }
    
    // Use solidityPacked to match Solidity's abi.encodePacked(uint64(chainId), packed)
    const packedParts = ethers.concat(parts)
    return ethers.solidityPacked(['uint64', 'bytes'], [chainId, packedParts])
  }

  // Helper function to prepare encoded proofs from fulfilled intents
  // This is used for fetchFee() calls and should NOT include chain ID prefix
  function prepareEncodedProofs(
    intentHashes: string[],
    claimants: string[],
  ): string {
    const parts: string[] = []
    for (let i = 0; i < intentHashes.length; i++) {
      const claimantBytes =
        claimants[i].length === 66
          ? claimants[i]
          : ethers.zeroPadValue(claimants[i], 32)
      parts.push(intentHashes[i])
      parts.push(claimantBytes)
    }
    return ethers.concat(parts)
  }

  async function deployMetaProverFixture(): Promise<{
    inbox: Inbox
    metaProver: MetaProver
    router: TestMetaRouter
    token: TestERC20
    owner: SignerWithAddress
    solver: SignerWithAddress
    claimant: SignerWithAddress
  }> {
    const [owner, solver, claimant] = await ethers.getSigners()
    const router = await (
      await ethers.getContractFactory('TestMetaRouter')
    ).deploy(ethers.ZeroAddress)

    const portal = await (await ethers.getContractFactory('Portal')).deploy()
    const inbox = await ethers.getContractAt('Inbox', await portal.getAddress())

    const token = await (
      await ethers.getContractFactory('TestERC20')
    ).deploy('token', 'tkn')

    const metaProver = await (
      await ethers.getContractFactory('MetaProver')
    ).deploy(
      await router.getAddress(),
      await inbox.getAddress(),
      [], // provers array
      200000, // default gas limit
    )

    return {
      inbox,
      metaProver,
      router,
      token,
      owner,
      solver,
      claimant,
    }
  }

  beforeEach(async (): Promise<void> => {
    ;({ inbox, metaProver, router, token, owner, solver, claimant } =
      await loadFixture(deployMetaProverFixture))
  })

  describe('1. Constructor', () => {
    it('should initialize with the correct router and inbox addresses', async () => {
      expect(await metaProver.ROUTER()).to.equal(await router.getAddress())
      expect(await metaProver.PORTAL()).to.equal(await inbox.getAddress())
    })

    it('should add constructor-provided provers to the whitelist', async () => {
      const additionalProver = await owner.getAddress()
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await router.getAddress(),
        await inbox.getAddress(),
        [
          ethers.zeroPadValue(additionalProver, 32),
          ethers.zeroPadValue(await inbox.getAddress(), 32),
        ],
        200000,
      )

      expect(
        await metaProver.isWhitelisted(
          ethers.zeroPadValue(additionalProver, 32),
        ),
      ).to.be.true
      expect(
        await metaProver.isWhitelisted(
          ethers.zeroPadValue(await inbox.getAddress(), 32),
        ),
      ).to.be.true
    })

    it('should return the correct proof type', async () => {
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(await router.getAddress(), await inbox.getAddress(), [], 200000)
      expect(await metaProver.getProofType()).to.equal('Meta')
    })
  })

  describe('2. Handle', () => {
    beforeEach(async () => {
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await router.getAddress(),
        await inbox.getAddress(),
        [
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          ethers.zeroPadValue(await router.getAddress(), 32),
        ],
        200000,
      )
    })

    it('should revert when msg.sender is not the router', async () => {
      await expect(
        metaProver.connect(claimant).handle(
          12345, // origin chain ID
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          ethers.sha256('0x'), // message
          [], // empty operations array
          [], // empty operationsData array
        ),
      ).to.be.revertedWithCustomError(metaProver, 'UnauthorizedSender')
    })

    it('should revert when sender field is not authorized', async () => {
      // Set metaProver as processor for router to allow it to receive messages
      await router.setProcessor(await metaProver.getAddress())

      await expect(
        router.simulateHandleMessage(
          12345, // origin chain ID
          ethers.zeroPadValue(await claimant.getAddress(), 32), // Unauthorized sender
          ethers.sha256('0x'), // message
        ),
      ).to.be.revertedWithCustomError(metaProver, 'UnauthorizedIncomingProof')
    })

    it('should record a single proven intent when called correctly', async () => {
      await router.setProcessor(await metaProver.getAddress())

      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = encodeMessageBody([intentHash], [claimantAddress])

      const proofDataBefore = await metaProver.provenIntents(intentHash)
      expect(proofDataBefore.claimant).to.eq(ethers.ZeroAddress)

      await expect(
        router.simulateHandleMessage(
          12345, // origin chain ID
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgBody,
        ),
      )
        .to.emit(metaProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress, 12345)

      const proofDataAfter = await metaProver.provenIntents(intentHash)
      expect(proofDataAfter.claimant).to.eq(claimantAddress)
    })

    it('should emit an event when intent is already proven', async () => {
      await router.setProcessor(await metaProver.getAddress())

      const intentHash = ethers.sha256('0x')
      const claimantAddress = await claimant.getAddress()
      const msgBody = encodeMessageBody([intentHash], [claimantAddress])

      // First handle call proves the intent
      await router.simulateHandleMessage(
        12345, // origin chain ID
        ethers.zeroPadValue(await inbox.getAddress(), 32),
        msgBody,
      )

      // Second handle call should emit IntentAlreadyProven
      await expect(
        router.simulateHandleMessage(
          12345, // origin chain ID
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgBody,
        ),
      )
        .to.emit(metaProver, 'IntentAlreadyProven')
        .withArgs(intentHash)
    })

    it('should handle batch proving of multiple intents', async () => {
      await router.setProcessor(await metaProver.getAddress())

      const intentHash = ethers.sha256('0x')
      const otherHash = ethers.sha256('0x1337')
      const claimantAddress = await claimant.getAddress()
      const otherAddress = await solver.getAddress()

      const msgBody = encodeMessageBody(
        [intentHash, otherHash],
        [claimantAddress, otherAddress],
      )

      await expect(
        router.simulateHandleMessage(
          12345, // origin chain ID
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgBody,
        ),
      )
        .to.emit(metaProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress, 12345)
        .to.emit(metaProver, 'IntentProven')
        .withArgs(otherHash, otherAddress, 12345)

      const proofData1 = await metaProver.provenIntents(intentHash)
      expect(proofData1.claimant).to.eq(claimantAddress)
      const proofData2 = await metaProver.provenIntents(otherHash)
      expect(proofData2.claimant).to.eq(otherAddress)
    })
  })

  describe('3. SendProof', () => {
    beforeEach(async () => {
      const chainId = 12345
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await router.getAddress(),
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )
    })

    it('should revert on underpayment', async () => {
      const portal = await ethers.getContractAt(
        'Portal',
        await inbox.getAddress(),
      )
      const intentSource = await ethers.getContractAt(
        'IIntentSource',
        await portal.getAddress(),
      )

      const salt = ethers.encodeBytes32String('test-underpayment')
      const deadline = (await time.latest()) + 3600
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)

      const intent: Intent = {
        destination: Number(
          (await metaProver.runner?.provider?.getNetwork())?.chainId,
        ),
        route: {
          salt: salt,
          deadline: deadline,
          portal: await inbox.getAddress(),
          tokens: [{ token: await token.getAddress(), amount: amount }],
          calls: [
            {
              target: await token.getAddress(),
              data: calldata,
              value: 0,
            },
          ],
        },
        reward: {
          creator: await owner.getAddress(),
          prover: await metaProver.getAddress(),
          deadline: deadline,
          nativeAmount: ethers.parseEther('0.01'),
          tokens: [] as TokenAmount[],
        },
      }

      const { intentHash, rewardHash, routeHash } = hashIntent(intent)

      await token.mint(owner.address, amount)
      await token.connect(owner).approve(await portal.getAddress(), amount)

      const tx = await intentSource
        .connect(owner)
        .publishAndFund(intent, false, {
          value: ethers.parseEther('0.01'),
        })
      await tx.wait()

      await token.mint(solver.address, amount)
      await token.connect(solver).approve(await inbox.getAddress(), amount)

      await inbox
        .connect(solver)
        .fulfill(
          intentHash,
          intent.route,
          rewardHash,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        )

      const sourceChainId = 12345
      const intentHashes = [intentHash]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await metaProver.getAddress()
      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,uint256)'],
        [[ethers.zeroPadValue(sourceChainProver, 32), gasLimit]],
      )

      expect(await router.sentMessages()).to.equal(0)

      const encodedProofs = prepareEncodedProofs(intentHashes, claimants)
      const fee = await metaProver.fetchFee(sourceChainId, encodedProofs, data)

      await expect(
        inbox.connect(solver).prove(
          await metaProver.getAddress(),
          sourceChainId,
          intentHashes,
          data,
          { value: fee - BigInt(1) }, // underpayment
        ),
      ).to.be.revertedWithCustomError(metaProver, 'InsufficientFee')
    })

    it('should reject sendProof from unauthorized source', async () => {
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await solver.getAddress()
      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,uint256)'],
        [[ethers.zeroPadValue(sourceChainProver, 32), gasLimit]],
      )

      const encodedProofs = prepareEncodedProofs(intentHashes, claimants)
      await expect(
        metaProver
          .connect(solver)
          .prove(owner.address, 123, encodedProofs, data),
      ).to.be.revertedWithCustomError(metaProver, 'UnauthorizedSender')
    })

    it('should handle exact fee payment with no refund needed', async () => {
      const portal = await ethers.getContractAt(
        'Portal',
        await inbox.getAddress(),
      )
      const intentSource = await ethers.getContractAt(
        'IIntentSource',
        await portal.getAddress(),
      )

      const salt = ethers.encodeBytes32String('test-exact-fee')
      const deadline = (await time.latest()) + 3600
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)

      const intent: Intent = {
        destination: Number(
          (await metaProver.runner?.provider?.getNetwork())?.chainId,
        ),
        route: {
          salt: salt,
          deadline: deadline,
          portal: await inbox.getAddress(),
          tokens: [{ token: await token.getAddress(), amount: amount }],
          calls: [
            {
              target: await token.getAddress(),
              data: calldata,
              value: 0,
            },
          ],
        },
        reward: {
          creator: await owner.getAddress(),
          prover: await metaProver.getAddress(),
          deadline: deadline,
          nativeAmount: ethers.parseEther('0.01'),
          tokens: [] as TokenAmount[],
        },
      }

      const { intentHash, rewardHash, routeHash } = hashIntent(intent)

      await token.mint(owner.address, amount)
      await token.connect(owner).approve(await portal.getAddress(), amount)

      const publishTx = await intentSource
        .connect(owner)
        .publishAndFund(intent, false, {
          value: ethers.parseEther('0.01'),
        })
      await publishTx.wait()

      await token.mint(solver.address, amount)
      await token.connect(solver).approve(await inbox.getAddress(), amount)

      await inbox
        .connect(solver)
        .fulfill(
          intentHash,
          intent.route,
          rewardHash,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        )

      const sourceChainId = 12345
      const intentHashes = [intentHash]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await inbox.getAddress()
      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,uint256)'],
        [[ethers.zeroPadValue(sourceChainProver, 32), gasLimit]],
      )

      const encodedProofs = prepareEncodedProofs(intentHashes, claimants)
      const fee = await metaProver.fetchFee(sourceChainId, encodedProofs, data)

      const routerFee = await router.FEE()
      expect(fee).to.equal(routerFee)

      const proveTx = await inbox
        .connect(solver)
        .prove(
          await metaProver.getAddress(),
          sourceChainId,
          intentHashes,
          data,
          { value: fee },
        )

      await proveTx.wait()

      expect(await router.sentMessages()).to.equal(1)
    })

    it('should handle custom metadata correctly', async () => {
      const portal = await ethers.getContractAt(
        'Portal',
        await inbox.getAddress(),
      )
      const intentSource = await ethers.getContractAt(
        'IIntentSource',
        await portal.getAddress(),
      )

      const salt = ethers.encodeBytes32String('test-custom-metadata')
      const deadline = (await time.latest()) + 3600
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)

      const intent: Intent = {
        destination: Number(
          (await metaProver.runner?.provider?.getNetwork())?.chainId,
        ),
        route: {
          salt: salt,
          deadline: deadline,
          portal: await inbox.getAddress(),
          tokens: [{ token: await token.getAddress(), amount: amount }],
          calls: [
            {
              target: await token.getAddress(),
              data: calldata,
              value: 0,
            },
          ],
        },
        reward: {
          creator: await owner.getAddress(),
          prover: await metaProver.getAddress(),
          deadline: deadline,
          nativeAmount: ethers.parseEther('0.01'),
          tokens: [] as TokenAmount[],
        },
      }

      const { intentHash, rewardHash, routeHash } = hashIntent(intent)

      await token.mint(owner.address, amount)
      await token.connect(owner).approve(await portal.getAddress(), amount)

      const publishTx = await intentSource
        .connect(owner)
        .publishAndFund(intent, false, {
          value: ethers.parseEther('0.01'),
        })
      await publishTx.wait()

      await token.mint(solver.address, amount)
      await token.connect(solver).approve(await inbox.getAddress(), amount)

      await inbox
        .connect(solver)
        .fulfill(
          intentHash,
          intent.route,
          rewardHash,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        )

      const sourceChainId = 123
      const intentHashes = [intentHash]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await metaProver.getAddress()
      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,uint256)'],
        [[ethers.zeroPadValue(sourceChainProver, 32), gasLimit]],
      )

      const encodedProofs = prepareEncodedProofs(intentHashes, claimants)
      const fee = await metaProver.fetchFee(sourceChainId, encodedProofs, data)

      const proveTx = await inbox
        .connect(owner)
        .prove(
          await metaProver.getAddress(),
          sourceChainId,
          intentHashes,
          data,
          {
            value: fee,
          },
        )

      await proveTx.wait()

      expect(await router.sentMessages()).to.equal(1)
    })

    it('should handle empty arrays gracefully', async () => {
      const sourceChainId = 123
      const intentHashes: string[] = []
      const claimants: string[] = []
      const sourceChainProver = await inbox.getAddress()
      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,uint256)'],
        [[ethers.zeroPadValue(sourceChainProver, 32), gasLimit]],
      )

      const encodedProofs = prepareEncodedProofs(intentHashes, claimants)
      const fee = await metaProver.fetchFee(sourceChainId, encodedProofs, data)

      const tx = await inbox
        .connect(owner)
        .prove(
          await metaProver.getAddress(),
          sourceChainId,
          intentHashes,
          data,
          {
            value: fee,
          },
        )

      await tx.wait()

      expect(await router.sentMessages()).to.equal(1)
    })

    it('should correctly format parameters in processAndFormat via fetchFee', async () => {
      const sourceChainId = 123
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]
      const sourceChainProver = await solver.getAddress()
      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,uint256)'],
        [[ethers.zeroPadValue(sourceChainProver, 32), gasLimit]],
      )

      const encodedProofs = prepareEncodedProofs(intentHashes, claimants)
      const fee = await metaProver.fetchFee(sourceChainId, encodedProofs, data)

      expect(fee).to.be.gt(0)
    })

    it('should correctly call dispatch in the prove method', async () => {
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(await router.getAddress(), await inbox.getAddress(), [], 200000)

      const sourceChainId = 12345
      const intentHashes = [
        ethers.keccak256('0x1234'),
        ethers.keccak256('0x5678'),
      ]
      const claimants = [
        ethers.zeroPadValue(await claimant.getAddress(), 32),
        ethers.zeroPadValue(await solver.getAddress(), 32),
      ]

      const sourceChainProver = ethers.zeroPadValue(
        await inbox.getAddress(),
        32,
      )
      const gasLimit = 200000
      const data = abiCoder.encode(
        ['tuple(bytes32,uint256)'],
        [[sourceChainProver, gasLimit]],
      )

      const encodedProofs = prepareEncodedProofs(intentHashes, claimants)
      const fee = await metaProver.fetchFee(sourceChainId, encodedProofs, data)
      const routerFee = await router.FEE()
      expect(fee).to.equal(routerFee)
    })

    it('should gracefully return funds to sender if they overpay', async () => {
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(await router.getAddress(), await inbox.getAddress(), [], 200000)

      const sourceChainId = 12345
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [ethers.zeroPadValue(await claimant.getAddress(), 32)]

      const sourceChainProver = ethers.zeroPadValue(
        await inbox.getAddress(),
        32,
      )
      const gasLimit = 200000
      const data = abiCoder.encode(
        ['tuple(bytes32,uint256)'],
        [[sourceChainProver, gasLimit]],
      )

      const encodedProofs = prepareEncodedProofs(intentHashes, claimants)
      const fee = await metaProver.fetchFee(sourceChainId, encodedProofs, data)
      const routerFee = await router.FEE()
      expect(fee).to.equal(routerFee)
    })
  })

  describe('4. Cross-VM Claimant Compatibility', () => {
    it('should skip non-EVM claimants when processing handle messages', async () => {
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await router.getAddress(),
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

      await router.setProcessor(await metaProver.getAddress())

      const intentHash1 = ethers.keccak256('0x1234')
      const intentHash2 = ethers.keccak256('0x5678')
      const validClaimant = ethers.zeroPadValue(await claimant.getAddress(), 32)

      const nonAddressClaimant = ethers.keccak256(
        ethers.toUtf8Bytes('non-evm-claimant-identifier'),
      )

      // Create message with both valid and invalid claimants
      // We need to use the raw bytes for the non-address claimant
      const rawPacked = ethers.concat([
        intentHash1, // 32 bytes
        validClaimant, // 32 bytes
        intentHash2, // 32 bytes
        nonAddressClaimant, // 32 bytes - Non-EVM address
      ])
      const msgBody = ethers.solidityPacked(['uint64', 'bytes'], [12345, rawPacked])

      await router.simulateHandleMessage(
        12345, // origin chain ID
        ethers.zeroPadValue(await inbox.getAddress(), 32),
        msgBody,
      )

      const proofData1 = await metaProver.provenIntents(intentHash1)
      expect(proofData1.claimant).to.eq(await claimant.getAddress())

      const proofData2 = await metaProver.provenIntents(intentHash2)
      expect(proofData2.claimant).to.eq(ethers.ZeroAddress)
    })

    it('should skip non-EVM claimants when processing cross-chain messages', async () => {
      const chainId = 12345
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await router.getAddress(),
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

      const portal = await ethers.getContractAt(
        'Portal',
        await inbox.getAddress(),
      )
      const intentSource = await ethers.getContractAt(
        'IIntentSource',
        await portal.getAddress(),
      )

      await token.mint(solver.address, amount * 2)
      await token.mint(owner.address, amount)

      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const salt = ethers.encodeBytes32String('0x987')
      const routeTokens = [{ token: await token.getAddress(), amount: amount }]

      const intent: Intent = {
        destination: Number(
          (await metaProver.runner?.provider?.getNetwork())?.chainId,
        ),
        route: {
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
        },
        reward: {
          creator: await owner.getAddress(),
          prover: await metaProver.getAddress(),
          deadline: timeStamp + 1000,
          nativeAmount: ethers.parseEther('0.01'),
          tokens: [] as TokenAmount[],
        },
      }

      const { intentHash, rewardHash, routeHash } = hashIntent(intent)
      const route = intent.route
      const reward = intent.reward

      await token.connect(owner).approve(await portal.getAddress(), amount)

      const publishTx = await intentSource
        .connect(owner)
        .publishAndFund(intent, false, {
          value: ethers.parseEther('0.01'),
        })
      await publishTx.wait()

      const isFunded = await intentSource.isIntentFunded(intent)
      expect(isFunded).to.be.true

      const nonAddressClaimant = ethers.keccak256(
        ethers.toUtf8Bytes('non-evm-claimant-identifier'),
      )

      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,uint256)'],
        [[ethers.zeroPadValue(await inbox.getAddress(), 32), gasLimit]],
      )

      await token.connect(solver).approve(await inbox.getAddress(), amount)

      // Get fee for fulfillment - Inbox will encode the proofs
      const fee = await metaProver.fetchFee(
        sourceChainID,
        '0x', // Empty encoded proofs - Inbox will populate this
        data,
      )

      await inbox
        .connect(solver)
        .fulfillAndProve(
          intentHash,
          route,
          rewardHash,
          nonAddressClaimant,
          await metaProver.getAddress(),
          sourceChainID,
          data,
          { value: fee },
        )

      expect(await inbox.claimants(intentHash)).to.eq(nonAddressClaimant)

      const provenIntent = await metaProver.provenIntents(intentHash)
      expect(provenIntent.claimant).to.eq(ethers.ZeroAddress)
    })
  })

  describe('5. End-to-End', () => {
    it('works end to end with message bridge', async () => {
      const chainId = 12345
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await router.getAddress(),
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

      await router.setProcessor(await metaProver.getAddress())

      const portal = await ethers.getContractAt(
        'Portal',
        await inbox.getAddress(),
      )
      const intentSource = await ethers.getContractAt(
        'IIntentSource',
        await portal.getAddress(),
      )

      await token.mint(solver.address, amount * 2)
      await token.mint(owner.address, amount)

      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const salt = ethers.encodeBytes32String('0x987')
      const routeTokens = [{ token: await token.getAddress(), amount: amount }]

      const intent: Intent = {
        destination: Number(
          (await metaProver.runner?.provider?.getNetwork())?.chainId,
        ),
        route: {
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
        },
        reward: {
          creator: await owner.getAddress(),
          prover: await metaProver.getAddress(),
          deadline: timeStamp + 1000,
          nativeAmount: ethers.parseEther('0.01'),
          tokens: [] as TokenAmount[],
        },
      }

      const { intentHash, rewardHash, routeHash } = hashIntent(intent)
      const route = intent.route
      const reward = intent.reward

      await token.connect(owner).approve(await portal.getAddress(), amount)

      const publishTx = await intentSource
        .connect(owner)
        .publishAndFund(intent, false, {
          value: ethers.parseEther('0.01'),
        })
      await publishTx.wait()

      const isFunded = await intentSource.isIntentFunded(intent)
      expect(isFunded).to.be.true

      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,uint256)'],
        [[ethers.zeroPadValue(await inbox.getAddress(), 32), gasLimit]],
      )

      await token.connect(solver).approve(await inbox.getAddress(), amount)

      const proofDataBefore = await metaProver.provenIntents(intentHash)
      expect(proofDataBefore.claimant).to.eq(ethers.ZeroAddress)

      // Get fee for fulfillment - Inbox will encode the proofs
      const fee = await metaProver.fetchFee(
        sourceChainID,
        '0x', // Empty encoded proofs - Inbox will populate this
        data,
      )

      await inbox
        .connect(solver)
        .fulfillAndProve(
          intentHash,
          route,
          rewardHash,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
          await metaProver.getAddress(),
          sourceChainID,
          data,
          { value: fee },
        )

      // Simulate the cross-chain message being received back to record the proof
      const msgBodyForReturn = encodeMessageBody(
        [intentHash],
        [await claimant.getAddress()],
      )

      await router.simulateHandleMessage(
        sourceChainID,
        ethers.zeroPadValue(await inbox.getAddress(), 32),
        msgBodyForReturn,
      )

      const proofDataAfter = await metaProver.provenIntents(intentHash)
      expect(proofDataAfter.claimant).to.eq(await claimant.getAddress())

      const msgBody = encodeMessageBody(
        [intentHash],
        [await claimant.getAddress()],
      )

      const simulatedMetaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await owner.getAddress(),
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

      await expect(
        simulatedMetaProver.connect(owner).handle(
          12345, // origin chain ID
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgBody,
          [], // empty operations array
          [], // empty operationsData array
        ),
      )
        .to.emit(simulatedMetaProver, 'IntentProven')
        .withArgs(intentHash, await claimant.getAddress(), 12345)

      const proofData = await simulatedMetaProver.provenIntents(intentHash)
      expect(proofData.claimant).to.eq(await claimant.getAddress())
    })

    it('should work with batched message bridge fulfillment end-to-end', async () => {
      metaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await router.getAddress(),
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

      await router.setProcessor(await metaProver.getAddress())

      const portal = await ethers.getContractAt(
        'Portal',
        await inbox.getAddress(),
      )
      const intentSource = await ethers.getContractAt(
        'IIntentSource',
        await portal.getAddress(),
      )

      await token.mint(solver.address, 2 * amount)
      await token.mint(owner.address, 2 * amount)

      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = (await time.latest()) + 1000
      const gasLimit = 200000
      const data = ethers.AbiCoder.defaultAbiCoder().encode(
        ['tuple(bytes32,uint256)'],
        [[ethers.zeroPadValue(await inbox.getAddress(), 32), gasLimit]],
      )

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
        prover: await metaProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeAmount: ethers.parseEther('0.01'),
        tokens: [],
      }

      const destination = Number(
        (await metaProver.runner?.provider?.getNetwork())?.chainId,
      )
      const intent0: Intent = {
        destination,
        route,
        reward,
      }
      const {
        intentHash: intentHash0,
        rewardHash: rewardHash0,
        routeHash: routeHash0,
      } = hashIntent(intent0)

      await token.connect(owner).approve(await portal.getAddress(), amount)
      await intentSource.connect(owner).publishAndFund(intent0, false, {
        value: ethers.parseEther('0.01'),
      })

      await token.connect(solver).approve(await inbox.getAddress(), amount)
      expect((await metaProver.provenIntents(intentHash0)).claimant).to.eq(
        ethers.ZeroAddress,
      )

      await inbox
        .connect(solver)
        .fulfill(
          intentHash0,
          route,
          rewardHash0,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        )

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
        prover: await metaProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeAmount: ethers.parseEther('0.01'),
        tokens: [],
      }
      const intent1: Intent = {
        destination,
        route: route1,
        reward: reward1,
      }
      const {
        intentHash: intentHash1,
        rewardHash: rewardHash1,
        routeHash: routeHash1,
      } = hashIntent(intent1)

      await token.connect(owner).approve(await portal.getAddress(), amount)
      await intentSource.connect(owner).publishAndFund(intent1, false, {
        value: ethers.parseEther('0.01'),
      })

      await token.connect(solver).approve(await inbox.getAddress(), amount)
      await inbox
        .connect(solver)
        .fulfill(
          intentHash1,
          route1,
          rewardHash1,
          ethers.zeroPadValue(await claimant.getAddress(), 32),
        )

      const proofDataBeforeBatch = await metaProver.provenIntents(intentHash1)
      expect(proofDataBeforeBatch.claimant).to.eq(ethers.ZeroAddress)

      const msgbody = encodeMessageBody(
        [intentHash0, intentHash1],
        [await claimant.getAddress(), await claimant.getAddress()],
      )

      // Get fee for batch - Inbox will encode the proofs
      const batchFee = await metaProver.fetchFee(
        sourceChainID,
        '0x', // Empty encoded proofs - Inbox will populate this
        data,
      )

      await expect(
        inbox
          .connect(solver)
          .prove(
            await metaProver.getAddress(),
            sourceChainID,
            [intentHash0, intentHash1],
            data,
            { value: batchFee },
          ),
      ).to.changeEtherBalance(solver, -Number(batchFee))

      // Simulate the cross-chain message being received back to record the proofs
      const batchMsgBody = encodeMessageBody(
        [intentHash0, intentHash1],
        [await claimant.getAddress(), await claimant.getAddress()],
      )

      await router.simulateHandleMessage(
        sourceChainID,
        ethers.zeroPadValue(await inbox.getAddress(), 32),
        batchMsgBody,
      )

      const proofData0 = await metaProver.provenIntents(intentHash0)
      expect(proofData0.claimant).to.eq(await claimant.getAddress())
      const proofData1 = await metaProver.provenIntents(intentHash1)
      expect(proofData1.claimant).to.eq(await claimant.getAddress())

      const simulatedMetaProver = await (
        await ethers.getContractFactory('MetaProver')
      ).deploy(
        await owner.getAddress(),
        await inbox.getAddress(),
        [ethers.zeroPadValue(await inbox.getAddress(), 32)],
        200000,
      )

      await expect(
        simulatedMetaProver.connect(owner).handle(
          12345, // origin chain ID
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          msgbody,
          [], // empty operations array
          [], // empty operationsData array
        ),
      )
        .to.emit(simulatedMetaProver, 'IntentProven')
        .withArgs(intentHash0, await claimant.getAddress(), 12345)
        .to.emit(simulatedMetaProver, 'IntentProven')
        .withArgs(intentHash1, await claimant.getAddress(), 12345)

      const proofData0Sim = await simulatedMetaProver.provenIntents(intentHash0)
      expect(proofData0Sim.claimant).to.eq(await claimant.getAddress())
      const proofData1Sim = await simulatedMetaProver.provenIntents(intentHash1)
      expect(proofData1Sim.claimant).to.eq(await claimant.getAddress())
    })
  })
})
