import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers'
import {
  time,
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers'
import { expect } from 'chai'
import { ethers } from 'hardhat'
import { PolymerProver, Inbox, TestERC20, TestCrossL2ProverV2 } from '../typechain-types'
import { encodeTransfer } from '../utils/encode'
import { hashIntent, TokenAmount, Intent } from '../utils/intent'

describe('PolymerProver Test', (): void => {
  let inbox: Inbox
  let crossL2ProverV2: TestCrossL2ProverV2
  let polymerProver: PolymerProver
  let token: TestERC20
  let owner: SignerWithAddress
  let solver: SignerWithAddress
  let claimant: SignerWithAddress
  let intent: Intent
  const amount: number = 1234567890
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  async function deployPolymerProverFixture(): Promise<{
    inbox: Inbox
    crossL2ProverV2: TestCrossL2ProverV2
    token: TestERC20
    owner: SignerWithAddress
    solver: SignerWithAddress
    claimant: SignerWithAddress
  }> {
    const [owner, solver, claimant] = await ethers.getSigners()
    
    const crossL2ProverV2 = await (
      await ethers.getContractFactory('TestCrossL2ProverV2')
    ).deploy(
      31337, // chainId
      ethers.ZeroAddress, // emittingContract (will be set properly in tests)
      '0x', // topics (will be set properly in tests)  
      '0x' // data (will be set properly in tests)
    )

    const inbox = await (await ethers.getContractFactory('Inbox')).deploy()

    const token = await (
      await ethers.getContractFactory('TestERC20')
    ).deploy('token', 'tkn')

    return {
      inbox,
      crossL2ProverV2,
      token,
      owner,
      solver,
      claimant,
    }
  }

  beforeEach(async (): Promise<void> => {
    ;({ inbox, crossL2ProverV2, token, owner, solver, claimant } = await loadFixture(
      deployPolymerProverFixture,
    ))
  })

  describe('1. Constructor', () => {
    it('should initialize with the correct owner and inbox addresses', async () => {
      polymerProver = await (
        await ethers.getContractFactory('PolymerProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress())

      expect(await polymerProver.INBOX()).to.equal(await inbox.getAddress())
      expect(await polymerProver.owner()).to.equal(await owner.getAddress())
    })

    it('should return the correct proof type', async () => {
      polymerProver = await (
        await ethers.getContractFactory('PolymerProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress())
      expect(await polymerProver.getProofType()).to.equal('Polymer')
    })

    it('should have correct constants', async () => {
      polymerProver = await (
        await ethers.getContractFactory('PolymerProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress())
      
      expect(await polymerProver.PROOF_SELECTOR()).to.equal(
        ethers.keccak256(ethers.toUtf8Bytes('IntentFulfilledFromSource(uint64,bytes)'))
      )
      expect(await polymerProver.EXPECTED_TOPIC_LENGTH()).to.equal(64)
    })


    it('should support ERC165 interface detection', async () => {
      polymerProver = await (
        await ethers.getContractFactory('PolymerProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress())
      
      const ERC165InterfaceId = '0x01ffc9a7' // ERC165 interface ID
      expect(await polymerProver.supportsInterface(ERC165InterfaceId)).to.be.true
    })
  })

  describe('2. Initialize', () => {
    beforeEach(async () => {
      polymerProver = await (
        await ethers.getContractFactory('PolymerProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress())
    })

    it('should initialize with CrossL2ProverV2 and whitelist settings', async () => {
      const chainIds = [1, 2]
      const whitelistedEmitters = [
        ethers.zeroPadValue(await solver.getAddress(), 32),
        ethers.zeroPadValue(await claimant.getAddress(), 32)
      ]

      await polymerProver.connect(owner).initialize(
        await crossL2ProverV2.getAddress(),
        chainIds,
        whitelistedEmitters
      )

      expect(await polymerProver.CROSS_L2_PROVER_V2()).to.equal(await crossL2ProverV2.getAddress())
      expect(await polymerProver.WHITELISTED_EMITTERS(1)).to.equal(whitelistedEmitters[0])
      expect(await polymerProver.WHITELISTED_EMITTERS(2)).to.equal(whitelistedEmitters[1])
    })

    it('should revert with zero address for CrossL2ProverV2', async () => {
      await expect(
        polymerProver.connect(owner).initialize(
          ethers.ZeroAddress,
          [1],
          [ethers.zeroPadValue(await solver.getAddress(), 32)]
        )
      ).to.be.revertedWithCustomError(polymerProver, 'ZeroAddress')
    })

    it('should revert with mismatched array lengths', async () => {
      await expect(
        polymerProver.connect(owner).initialize(
          await crossL2ProverV2.getAddress(),
          [1, 2],
          [ethers.zeroPadValue(await solver.getAddress(), 32)]
        )
      ).to.be.revertedWithCustomError(polymerProver, 'SizeMismatch')
    })

    it('should renounce ownership after initialization', async () => {
      await polymerProver.connect(owner).initialize(
        await crossL2ProverV2.getAddress(),
        [1],
        [ethers.zeroPadValue(await solver.getAddress(), 32)]
      )

      expect(await polymerProver.owner()).to.equal(ethers.ZeroAddress)
    })
  })

  describe('3. Validate', () => {
    beforeEach(async () => {
      polymerProver = await (
        await ethers.getContractFactory('PolymerProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress())

      await polymerProver.connect(owner).initialize(
        await crossL2ProverV2.getAddress(),
        [31337], // Hardhat default chain ID
        [ethers.zeroPadValue(await inbox.getAddress(), 32)]
      )
    })

    it('should validate proof and process intents', async () => {
      const intentHash = ethers.keccak256('0x1234')
      const claimantAddress = await claimant.getAddress()
      
      // Prepare proof data (intentHash + claimant as bytes32)
      const proofData = ethers.concat([
        intentHash,
        ethers.zeroPadValue(claimantAddress, 32)
      ])

      // Mock the CrossL2ProverV2 response
      await crossL2ProverV2.setAll(
        31337, // destinationChainId
        await inbox.getAddress(), // emittingContract
        ethers.concat([
          ethers.keccak256(ethers.toUtf8Bytes('IntentFulfilledFromSource(uint64,bytes)')), // event signature
          ethers.zeroPadValue(ethers.toBeHex(31337), 32) // source chain ID
        ]), // topics
        proofData // data
      )

      await expect(
        polymerProver.validate(ethers.zeroPadValue(ethers.toBeHex(1), 32)) // Use index 1 (second entry)
      )
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(intentHash, claimantAddress)

      const proofResult = await polymerProver.provenIntents(intentHash)
      expect(proofResult.claimant).to.equal(claimantAddress)
      expect(proofResult.destinationChainID).to.equal(31337)
    })

    it('should revert with invalid emitting contract', async () => {
      await crossL2ProverV2.setAll(
        31337,
        await solver.getAddress(), // Not whitelisted
        ethers.concat([
          ethers.keccak256(ethers.toUtf8Bytes('IntentFulfilledFromSource(uint64,bytes)')),
          ethers.zeroPadValue(ethers.toBeHex(31337), 32)
        ]),
        ethers.concat([
          ethers.keccak256('0x1234'),
          ethers.zeroPadValue(await claimant.getAddress(), 32)
        ])
      )

      await expect(
        polymerProver.validate(ethers.zeroPadValue(ethers.toBeHex(1), 32)) // Use index 1
      ).to.be.revertedWithCustomError(polymerProver, 'InvalidEmittingContract')
    })

    it('should revert with invalid topics length', async () => {
      await crossL2ProverV2.setAll(
        31337,
        await inbox.getAddress(),
        '0x1234', // Invalid topics length (not 64 bytes)
        ethers.concat([
          ethers.keccak256('0x1234'),
          ethers.zeroPadValue(await claimant.getAddress(), 32)
        ])
      )

      await expect(
        polymerProver.validate(ethers.zeroPadValue(ethers.toBeHex(1), 32))
      ).to.be.revertedWithCustomError(polymerProver, 'InvalidTopicsLength')
    })

    it('should revert with empty proof data', async () => {
      await crossL2ProverV2.setAll(
        31337,
        await inbox.getAddress(),
        ethers.concat([
          ethers.keccak256(ethers.toUtf8Bytes('IntentFulfilledFromSource(uint64,bytes)')),
          ethers.zeroPadValue(ethers.toBeHex(31337), 32)
        ]),
        '0x' // Empty data
      )

      await expect(
        polymerProver.validate(ethers.zeroPadValue(ethers.toBeHex(1), 32))
      ).to.be.revertedWithCustomError(polymerProver, 'EmptyProofData')
    })

    it('should revert with invalid event signature', async () => {
      await crossL2ProverV2.setAll(
        31337,
        await inbox.getAddress(),
        ethers.concat([
          ethers.keccak256('0x1234'), // Wrong event signature
          ethers.zeroPadValue(ethers.toBeHex(31337), 32)
        ]),
        ethers.concat([
          ethers.keccak256('0x1234'),
          ethers.zeroPadValue(await claimant.getAddress(), 32)
        ])
      )

      await expect(
        polymerProver.validate(ethers.zeroPadValue(ethers.toBeHex(1), 32))
      ).to.be.revertedWithCustomError(polymerProver, 'InvalidEventSignature')
    })

    it('should handle multiple intents in batch', async () => {
      const intentHash1 = ethers.keccak256('0x1234')
      const intentHash2 = ethers.keccak256('0x5678')
      const claimantAddress = await claimant.getAddress()
      
      // Prepare proof data for 2 intents
      const proofData = ethers.concat([
        intentHash1,
        ethers.zeroPadValue(claimantAddress, 32),
        intentHash2,
        ethers.zeroPadValue(claimantAddress, 32)
      ])

      await crossL2ProverV2.setAll(
        31337,
        await inbox.getAddress(),
        ethers.concat([
          ethers.keccak256(ethers.toUtf8Bytes('IntentFulfilledFromSource(uint64,bytes)')),
          ethers.zeroPadValue(ethers.toBeHex(31337), 32)
        ]),
        proofData
      )

      await expect(
        polymerProver.validate(ethers.zeroPadValue(ethers.toBeHex(1), 32))
      )
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(intentHash1, claimantAddress)
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(intentHash2, claimantAddress)
    })

    it('should emit IntentAlreadyProven for duplicate proofs', async () => {
      const intentHash = ethers.keccak256('0x1234')
      const claimantAddress = await claimant.getAddress()
      
      const proofData = ethers.concat([
        intentHash,
        ethers.zeroPadValue(claimantAddress, 32)
      ])

      await crossL2ProverV2.setAll(
        31337,
        await inbox.getAddress(),
        ethers.concat([
          ethers.keccak256(ethers.toUtf8Bytes('IntentFulfilledFromSource(uint64,bytes)')),
          ethers.zeroPadValue(ethers.toBeHex(31337), 32)
        ]),
        proofData
      )

      // First validation
      await polymerProver.validate(ethers.zeroPadValue(ethers.toBeHex(1), 32))

      // Second validation should emit IntentAlreadyProven
      await expect(
        polymerProver.validate(ethers.zeroPadValue(ethers.toBeHex(1), 32))
      ).to.emit(polymerProver, 'IntentAlreadyProven')
    })
  })


  describe('4. Prove', () => {
    beforeEach(async () => {
      // Use owner as inbox so we can test prove function
      polymerProver = await (
        await ethers.getContractFactory('PolymerProver')
      ).deploy(await owner.getAddress(), await owner.getAddress())

      await polymerProver.connect(owner).initialize(
        await crossL2ProverV2.getAddress(),
        [31337],
        [ethers.zeroPadValue(await inbox.getAddress(), 32)]
      )
    })

    it('should emit IntentFulfilledFromSource event', async () => {
      const sourceChainId = 12345
      const intentHashes = [ethers.keccak256('0x1234')]
      const claimants = [await claimant.getAddress()]
      
      // Prepare data as (intentHash, claimant) pairs
      const data = ethers.concat([
        intentHashes[0],
        ethers.zeroPadValue(claimants[0], 32)
      ])

      await expect(
        polymerProver.connect(owner).prove(
          await solver.getAddress(),
          sourceChainId,
          intentHashes,
          claimants,
          data
        )
      )
        .to.emit(polymerProver, 'IntentFulfilledFromSource')
        .withArgs(sourceChainId, data)
    })

    it('should revert when not called by inbox', async () => {
      await expect(
        polymerProver.connect(solver).prove(
          await solver.getAddress(),
          12345,
          [],
          [],
          '0x'
        )
      ).to.be.revertedWithCustomError(polymerProver, 'OnlyInbox')
    })

    it('should handle empty data gracefully', async () => {
      await expect(
        polymerProver.connect(owner).prove(
          await solver.getAddress(),
          12345,
          [],
          [],
          '0x'
        )
      ).to.not.be.reverted
    })

    it('should revert with invalid data length', async () => {
      const invalidData = '0x1234' // Not divisible by 64

      await expect(
        polymerProver.connect(owner).prove(
          await solver.getAddress(),
          12345,
          [],
          [],
          invalidData
        )
      ).to.be.revertedWithCustomError(polymerProver, 'ArrayLengthMismatch')
    })

    it('should revert when data exceeds max size', async () => {
      // Create data that exceeds MAX_LOG_DATA_SIZE (32 * 1024 bytes) but is divisible by 64
      const maxSize = 32 * 1024
      const largeDataSize = maxSize + 64 // Add one more 64-byte chunk to exceed limit
      const largeData = '0x' + '00'.repeat(largeDataSize)

      await expect(
        polymerProver.connect(owner).prove(
          await solver.getAddress(),
          12345,
          [],
          [],
          largeData
        )
      ).to.be.revertedWithCustomError(polymerProver, 'MaxDataSizeExceeded')
    })
  })

  describe('5. ValidateBatch', () => {
    beforeEach(async () => {
      polymerProver = await (
        await ethers.getContractFactory('PolymerProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress())

      await polymerProver.connect(owner).initialize(
        await crossL2ProverV2.getAddress(),
        [31337],
        [ethers.zeroPadValue(await inbox.getAddress(), 32)]
      )
    })

    it('should validate multiple proofs in batch', async () => {
      const intentHash1 = ethers.keccak256('0x1234')
      const claimantAddress = await claimant.getAddress()
      
      const proofData = ethers.concat([
        intentHash1,
        ethers.zeroPadValue(claimantAddress, 32)
      ])

      // Set up multiple mock responses
      await crossL2ProverV2.setAll(
        31337,
        await inbox.getAddress(),
        ethers.concat([
          ethers.keccak256(ethers.toUtf8Bytes('IntentFulfilledFromSource(uint64,bytes)')),
          ethers.zeroPadValue(ethers.toBeHex(31337), 32)
        ]),
        proofData
      )

      await crossL2ProverV2.setAll(
        31337,
        await inbox.getAddress(),
        ethers.concat([
          ethers.keccak256(ethers.toUtf8Bytes('IntentFulfilledFromSource(uint64,bytes)')),
          ethers.zeroPadValue(ethers.toBeHex(31337), 32)
        ]),
        proofData
      )

      const proofs = [
        ethers.zeroPadValue(ethers.toBeHex(1), 32), 
        ethers.zeroPadValue(ethers.toBeHex(2), 32)
      ] // Use proper indices

      await expect(
        polymerProver.validateBatch(proofs)
      )
        .to.emit(polymerProver, 'IntentProven')
        .withArgs(intentHash1, claimantAddress)
    })
  })

  describe('6. ChallengeIntentProof', () => {
    beforeEach(async () => {
      polymerProver = await (
        await ethers.getContractFactory('PolymerProver')
      ).deploy(await owner.getAddress(), await inbox.getAddress())

      await polymerProver.connect(owner).initialize(
        await crossL2ProverV2.getAddress(),
        [31337, 666, 54321], // Add more chain IDs for testing
        [
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          ethers.zeroPadValue(await inbox.getAddress(), 32),
          ethers.zeroPadValue(await inbox.getAddress(), 32)
        ]
      )

      // Create a test intent
      const sourceChainID = 12345
      const calldata = await encodeTransfer(await claimant.getAddress(), amount)
      const timeStamp = Math.floor(Date.now() / 1000) + 1000

      const routeTokens = [
        { token: await token.getAddress(), amount: amount }
      ]
      const route = {
        salt: ethers.encodeBytes32String('salt'),
        source: sourceChainID,
        destination: 54321,
        inbox: await inbox.getAddress(),
        tokens: routeTokens,
        calls: [
          {
            target: await token.getAddress(),
            data: calldata,
            value: 0
          }
        ]
      }
      const reward = {
        creator: await owner.getAddress(),
        prover: await polymerProver.getAddress(),
        deadline: timeStamp + 1000,
        nativeValue: 1n,
        tokens: []
      }
      intent = { route, reward }
    })

    it('should clear claimant and emit BadProofCleared for incorrect destination chain ID', async () => {
      const intentHash = hashIntent(intent).intentHash
      const badChainID = 666

      // First, manually set up a bad proof by setting the proof data directly
      // We'll simulate this by validating a proof with wrong chain ID
      const claimantAddress = await claimant.getAddress()
      const proofData = ethers.concat([
        intentHash,
        ethers.zeroPadValue(claimantAddress, 32)
      ])

      await crossL2ProverV2.setAll(
        badChainID, // Wrong destination chain
        await inbox.getAddress(),
        ethers.concat([
          ethers.keccak256(ethers.toUtf8Bytes('IntentFulfilledFromSource(uint64,bytes)')),
          ethers.zeroPadValue(ethers.toBeHex(31337), 32)
        ]),
        proofData
      )

      // Validate with wrong chain ID to create bad proof
      await polymerProver.validate(ethers.zeroPadValue(ethers.toBeHex(1), 32))

      // Verify bad proof is recorded
      const proofBefore = await polymerProver.provenIntents(intentHash)
      expect(proofBefore.claimant).to.equal(claimantAddress)
      expect(proofBefore.destinationChainID).to.equal(badChainID)

      // Challenge the proof
      await expect(
        polymerProver.challengeIntentProof(intent)
      )
        .to.emit(polymerProver, 'BadProofCleared')
        .withArgs(intentHash)

      // Verify proof is cleared and chain ID updated
      const proofAfter = await polymerProver.provenIntents(intentHash)
      expect(proofAfter.claimant).to.equal(ethers.ZeroAddress)
      expect(proofAfter.destinationChainID).to.equal(intent.route.destination)
    })

    it('should update destination chain ID when challenging unproven intent', async () => {
      const intentHash = hashIntent(intent).intentHash

      // Challenge an intent that hasn't been proven yet
      await polymerProver.challengeIntentProof(intent)

      // Should set the correct destination chain ID
      const proofData = await polymerProver.provenIntents(intentHash)
      expect(proofData.claimant).to.equal(ethers.ZeroAddress)
      expect(proofData.destinationChainID).to.equal(intent.route.destination)
    })

    it('should do nothing when destination chain ID is already correct', async () => {
      const intentHash = hashIntent(intent).intentHash
      const correctChainID = intent.route.destination

      // Set up a correct proof
      const claimantAddress = await claimant.getAddress()
      const proofData = ethers.concat([
        intentHash,
        ethers.zeroPadValue(claimantAddress, 32)
      ])

      await crossL2ProverV2.setAll(
        correctChainID, // Correct destination chain
        await inbox.getAddress(),
        ethers.concat([
          ethers.keccak256(ethers.toUtf8Bytes('IntentFulfilledFromSource(uint64,bytes)')),
          ethers.zeroPadValue(ethers.toBeHex(31337), 32)
        ]),
        proofData
      )

      // Validate with correct chain ID
      await polymerProver.validate(ethers.zeroPadValue(ethers.toBeHex(1), 32))

      // Verify correct proof is recorded
      const proofBefore = await polymerProver.provenIntents(intentHash)
      expect(proofBefore.claimant).to.equal(claimantAddress)
      expect(proofBefore.destinationChainID).to.equal(correctChainID)

      // Challenge should do nothing
      await polymerProver.challengeIntentProof(intent)

      // Verify proof is unchanged
      const proofAfter = await polymerProver.provenIntents(intentHash)
      expect(proofAfter.claimant).to.equal(claimantAddress)
      expect(proofAfter.destinationChainID).to.equal(correctChainID)
    })
  })
})