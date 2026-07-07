import { expect } from 'chai'
import { ethers } from 'hardhat'
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import { TestPolicy } from '../typechain-types'

describe('Edge Cases and Integration Tests', function () {
  let owner: SignerWithAddress
  let user: SignerWithAddress
  let solver: SignerWithAddress
  let portal: SignerWithAddress

  let testProver: TestPolicy

  const sourceChain = 1
  const destChain = 137

  beforeEach(async function () {
    ;[owner, user, solver, portal] = await ethers.getSigners()

    // Deploy test prover
    const TestPolicy = await ethers.getContractFactory('TestPolicy')
    testProver = await TestPolicy.deploy(portal.address)

    // Skip inbox and intent source deployment for edge case tests
    // as they're not needed for testing the prover interface directly
  })

  describe('Invalid Encoding Length Tests', function () {
    it('should revert with encoding not multiple of 64 bytes', async function () {
      // Get current chain ID
      const chainId = (await ethers.provider.getNetwork()).chainId
      const chainIdHex = chainId.toString(16).padStart(16, '0')

      // 8 bytes chain ID + 65 bytes - not multiple of 64
      const invalidProofs = '0x' + chainIdHex + '00'.repeat(65)

      await expect(
        testProver.receiveProofs(owner.address, sourceChain, invalidProofs, '0x'),
      ).to.be.revertedWithCustomError(testProver, 'ArrayLengthMismatch')

      // Just 7 bytes (less than chain ID)
      const singleByte = '0x' + '00'.repeat(7)
      await expect(
        testProver.receiveProofs(owner.address, sourceChain, singleByte, '0x'),
      ).to.be.revertedWithCustomError(testProver, 'InvalidProofMessage')

      // 8 bytes chain ID + 127 bytes
      const oddLength = '0x' + chainIdHex + '00'.repeat(127)
      await expect(
        testProver.receiveProofs(owner.address, sourceChain, oddLength, '0x'),
      ).to.be.revertedWithCustomError(testProver, 'ArrayLengthMismatch')
    })

    it('should handle empty proofs correctly', async function () {
      // Get current chain ID
      const chainId = (await ethers.provider.getNetwork()).chainId
      const chainIdHex = chainId.toString(16).padStart(16, '0')

      // Just chain ID with no proofs
      const emptyProofs = '0x' + chainIdHex

      // Should not revert with empty proofs
      await expect(
        testProver.receiveProofs(owner.address, sourceChain, emptyProofs, '0x'),
      ).to.not.be.reverted
    })
  })

  describe('Fulfillment-hash 2nd-word Tests', function () {
    it('records a non-zero 2nd word as a fulfillmentHash (no claimant-shape check on receive)', async function () {
      const intentHash = ethers.id('test-intent')
      // v3: the 2nd word is now an opaque fulfillmentHash; any non-zero value is recorded as-is.
      const fulfillmentHash =
        '0x0000000100000000000000000000000000000000000000000000000000000001'

      // Get current chain ID
      const chainId = (await ethers.provider.getNetwork()).chainId
      const chainIdBytes = ethers.zeroPadValue(ethers.toBeHex(chainId), 8)

      // Encode as chain ID + (intentHash, fulfillmentHash)
      const encodedProofs = ethers.concat([
        chainIdBytes,
        intentHash,
        fulfillmentHash,
      ])

      await testProver.receiveProofs(owner.address, sourceChain, encodedProofs, '0x')

      // Verify intent was proven with the supplied fulfillmentHash
      const proof = await testProver.provenIntents(intentHash)
      expect(proof.fulfillmentHash).to.equal(fulfillmentHash)
      expect(proof.destination).to.equal(sourceChain)
    })

    it('should skip a zero 2nd word (fulfillmentHash)', async function () {
      const intentHash = ethers.id('test-intent')
      const zeroFulfillment = ethers.ZeroHash

      // Get current chain ID
      const chainId = (await ethers.provider.getNetwork()).chainId
      const chainIdBytes = ethers.zeroPadValue(ethers.toBeHex(chainId), 8)

      const encodedProofs = ethers.concat([
        chainIdBytes,
        intentHash,
        zeroFulfillment,
      ])

      // Should succeed but skip the zero fulfillmentHash
      await testProver.receiveProofs(owner.address, sourceChain, encodedProofs, '0x')

      // Verify intent was not proven
      const proof = await testProver.provenIntents(intentHash)
      expect(proof.fulfillmentHash).to.equal(ethers.ZeroHash)
      expect(proof.destination).to.equal(0)
    })

    it('records a high-bytes (non-EVM shaped) 2nd word as a fulfillmentHash', async function () {
      const intentHash = ethers.id('cross-vm-intent')
      // High bytes set - previously treated as a non-EVM claimant to skip; now an opaque fulfillmentHash.
      const fulfillmentHash = '0x' + 'f'.repeat(16) + '0'.repeat(47) + '1'

      // Get current chain ID
      const chainId = (await ethers.provider.getNetwork()).chainId
      const chainIdBytes = ethers.zeroPadValue(ethers.toBeHex(chainId), 8)

      const encodedProofs = ethers.concat([
        chainIdBytes,
        intentHash,
        fulfillmentHash,
      ])

      // Should not revert
      await testProver.receiveProofs(owner.address, sourceChain, encodedProofs, '0x')

      // Verify intent was proven with the supplied fulfillmentHash
      const proof = await testProver.provenIntents(intentHash)
      expect(proof.fulfillmentHash).to.equal(fulfillmentHash)
      expect(proof.destination).to.equal(sourceChain)
    })
  })

  describe('Malformed Proof Data Tests', function () {
    it('should record all non-zero fulfillmentHashes in a batch', async function () {
      const hashes = [
        ethers.id('intent1'),
        ethers.id('intent2'),
        ethers.id('intent3'),
      ]

      // v3: every non-zero 2nd word is recorded as a fulfillmentHash (no per-entry validity check).
      const fulfillments = [
        ethers.zeroPadValue(solver.address, 32),
        '0x0000000100000000000000000000000000000000000000000000000000000001',
        ethers.zeroPadValue(user.address, 32),
      ]

      // Get current chain ID
      const chainId = (await ethers.provider.getNetwork()).chainId
      const chainIdBytes = ethers.zeroPadValue(ethers.toBeHex(chainId), 8)

      // Encode chain ID + all pairs
      let encodedProofs = chainIdBytes
      for (let i = 0; i < hashes.length; i++) {
        encodedProofs = ethers.concat([
          encodedProofs,
          hashes[i],
          fulfillments[i],
        ])
      }

      await testProver.receiveProofs(owner.address, sourceChain, encodedProofs, '0x')

      // Verify results - all three should be proven with their fulfillmentHash
      for (let i = 0; i < hashes.length; i++) {
        const proof = await testProver.provenIntents(hashes[i])
        expect(proof.fulfillmentHash).to.equal(fulfillments[i])
        expect(proof.destination).to.equal(sourceChain)
      }
    })

    it('should process large batch successfully', async function () {
      const numProofs = 50

      // Get current chain ID
      const chainId = (await ethers.provider.getNetwork()).chainId
      const chainIdBytes = ethers.zeroPadValue(ethers.toBeHex(chainId), 8)

      let encodedProofs = chainIdBytes

      for (let i = 0; i < numProofs; i++) {
        const intentHash = ethers.id(`intent-${i}`)
        const fulfillmentHash = ethers.zeroPadValue(ethers.toBeHex(1000 + i), 32)

        encodedProofs = ethers.concat([
          encodedProofs,
          intentHash,
          fulfillmentHash,
        ])
      }

      // Should process successfully
      await testProver.receiveProofs(owner.address, sourceChain, encodedProofs, '0x')

      // Verify a sample proof
      const checkHash = ethers.id('intent-25')
      const proof = await testProver.provenIntents(checkHash)

      expect(proof.fulfillmentHash).to.equal(
        ethers.zeroPadValue(ethers.toBeHex(1025), 32),
      )
      expect(proof.destination).to.equal(sourceChain)
    })
  })

  describe('Edge Case Encoding Helpers', function () {
    it('should correctly encode proof pairs', async function () {
      const intentHash = ethers.id('test')
      const claimant = ethers.zeroPadValue(solver.address, 32)

      // Manual encoding
      const encoded = ethers.concat([intentHash, claimant])

      expect(encoded.length).to.equal(130) // 64 bytes * 2 chars per byte + "0x" prefix
      expect(encoded.slice(0, 66)).to.equal(intentHash)
      expect('0x' + encoded.slice(66)).to.equal(claimant)
    })

    it('should handle encoding with special addresses', async function () {
      const specialAddresses = [
        ethers.ZeroAddress,
        '0x' + 'F'.repeat(40),
        '0x0000000000000000000000000000000000000001',
        '0x' + '1234567890'.repeat(4),
      ]

      for (const addr of specialAddresses) {
        const intentHash = ethers.id(addr)
        const claimant = ethers.zeroPadValue(addr, 32)
        const encoded = ethers.concat([intentHash, claimant])

        expect(encoded.length).to.equal(130) // 64 bytes * 2 + "0x"

        // Only process if valid address
        if (addr !== ethers.ZeroAddress) {
          // Would succeed with valid address format
          const isValid = ethers.isAddress(addr)
          expect(isValid).to.be.true
        }
      }
    })
  })
})
