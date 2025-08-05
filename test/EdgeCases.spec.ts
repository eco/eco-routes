import { expect } from 'chai'
import { ethers } from 'hardhat'
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import { TestProver } from '../typechain-types'

describe('Edge Cases and Integration Tests', function () {
  let owner: SignerWithAddress
  let user: SignerWithAddress
  let solver: SignerWithAddress
  let portal: SignerWithAddress

  let testProver: TestProver

  const sourceChain = 1
  const destChain = 137

  beforeEach(async function () {
    ;[owner, user, solver, portal] = await ethers.getSigners()

    // Deploy test prover
    const TestProver = await ethers.getContractFactory('TestProver')
    testProver = await TestProver.deploy(portal.address)

    // Skip inbox and intent source deployment for edge case tests
    // as they're not needed for testing the prover interface directly
  })

  describe('Invalid Encoding Length Tests', function () {
    it('should revert with encoding not multiple of 64 bytes', async function () {
      // 65 bytes - not multiple of 64
      const invalidProofs = '0x' + '00'.repeat(65)

      await expect(
        testProver.prove(owner.address, sourceChain, invalidProofs, '0x'),
      ).to.be.revertedWithCustomError(testProver, 'ArrayLengthMismatch')

      // 1 byte
      const singleByte = '0x00'
      await expect(
        testProver.prove(owner.address, sourceChain, singleByte, '0x'),
      ).to.be.revertedWithCustomError(testProver, 'ArrayLengthMismatch')

      // 127 bytes
      const oddLength = '0x' + '00'.repeat(127)
      await expect(
        testProver.prove(owner.address, sourceChain, oddLength, '0x'),
      ).to.be.revertedWithCustomError(testProver, 'ArrayLengthMismatch')
    })

    it('should handle empty proofs correctly', async function () {
      const emptyProofs = '0x'

      // Should not revert with empty proofs
      await expect(
        testProver.prove(owner.address, sourceChain, emptyProofs, '0x'),
      ).to.not.be.reverted
    })
  })

  describe('Invalid Claimant Address Tests', function () {
    it('should skip invalid claimant address', async function () {
      const intentHash = ethers.id('test-intent')
      const invalidClaimant =
        '0x0000000100000000000000000000000000000000000000000000000000000001' // High bytes set

      // Encode as (intentHash, claimant)
      const encodedProofs = ethers.concat([intentHash, invalidClaimant])

      // Should succeed but skip the invalid claimant
      await testProver.prove(owner.address, sourceChain, encodedProofs, '0x')

      // Verify intent was not proven
      const proof = await testProver.provenIntents(intentHash)
      expect(proof.claimant).to.equal(ethers.ZeroAddress)
      expect(proof.destination).to.equal(0)
    })

    it('should skip zero claimant address', async function () {
      const intentHash = ethers.id('test-intent')
      const zeroClaimant = ethers.ZeroHash

      const encodedProofs = ethers.concat([intentHash, zeroClaimant])

      // Should succeed but skip the zero claimant
      await testProver.prove(owner.address, sourceChain, encodedProofs, '0x')

      // Verify intent was not proven
      const proof = await testProver.provenIntents(intentHash)
      expect(proof.claimant).to.equal(ethers.ZeroAddress)
      expect(proof.destination).to.equal(0)
    })

    it('should skip non-EVM claimant addresses', async function () {
      const intentHash = ethers.id('cross-vm-intent')
      // High bytes set - indicates non-EVM address
      const crossVMClaimant = '0x' + 'F'.repeat(16) + '0'.repeat(47) + '1'

      const encodedProofs = ethers.concat([intentHash, crossVMClaimant])

      // Should not revert
      await testProver.prove(owner.address, sourceChain, encodedProofs, '0x')

      // Verify intent was not proven (skipped)
      const proof = await testProver.provenIntents(intentHash)
      expect(proof.claimant).to.equal(ethers.ZeroAddress)
      expect(proof.destination).to.equal(0)
    })
  })

  describe('Malformed Proof Data Tests', function () {
    it('should handle batch with mixed valid/invalid claimants', async function () {
      const hashes = [
        ethers.id('intent1'),
        ethers.id('intent2'),
        ethers.id('intent3'),
      ]

      const claimants = [
        ethers.zeroPadValue(solver.address, 32), // Valid
        '0x0000000100000000000000000000000000000000000000000000000000000001', // Invalid - high bytes set
        ethers.zeroPadValue(user.address, 32), // Valid
      ]

      // Encode all pairs
      let encodedProofs = '0x'
      for (let i = 0; i < hashes.length; i++) {
        encodedProofs += hashes[i].slice(2) + claimants[i].slice(2)
      }

      // Should succeed but skip the invalid claimant
      await testProver.prove(owner.address, sourceChain, encodedProofs, '0x')

      // Verify results - first and third should be proven, second skipped
      for (let i = 0; i < hashes.length; i++) {
        const proof = await testProver.provenIntents(hashes[i])
        if (i === 1) {
          // Second one should be skipped (invalid claimant)
          expect(proof.claimant).to.equal(ethers.ZeroAddress)
          expect(proof.destination).to.equal(0)
        } else {
          // First and third should be proven
          expect(proof.claimant).to.not.equal(ethers.ZeroAddress)
          expect(proof.destination).to.equal(sourceChain)
        }
      }
    })

    it('should process large batch successfully', async function () {
      const numProofs = 50
      let encodedProofs = '0x'

      for (let i = 0; i < numProofs; i++) {
        const intentHash = ethers.id(`intent-${i}`)
        const claimant = ethers.zeroPadValue(ethers.toBeHex(1000 + i), 32)

        encodedProofs += intentHash.slice(2) + claimant.slice(2)
      }

      // Should process successfully
      await testProver.prove(owner.address, sourceChain, encodedProofs, '0x')

      // Verify a sample proof
      const checkHash = ethers.id('intent-25')
      const proof = await testProver.provenIntents(checkHash)

      expect(proof.claimant).to.equal(
        ethers.getAddress('0x' + (1025).toString(16).padStart(40, '0')),
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
