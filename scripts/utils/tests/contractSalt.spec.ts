import { describe, it, expect } from '@jest/globals'
import { getContractSalt, getHyperProverSalt } from '../contractSalt'
import { createGuardedSaltForDeployer } from '../guardedSalt'

describe('contractSalt', () => {
  const testSalt =
    '0xadd7de6a903be02863c5a58c2bd130054ee97ff231a8d31f6c7ad30fe6b6e5e9'
  const guardedSalt = createGuardedSaltForDeployer(testSalt, false)

  describe('getContractSalt', () => {
    it('should generate different salts for different contract names', () => {
      const intentSourceSalt = getContractSalt(
        guardedSalt,
        'INTENT_SOURCE',
        false,
      )
      const inboxSalt = getContractSalt(guardedSalt, 'INBOX', false)

      expect(intentSourceSalt).not.toBe(inboxSalt)
      expect(intentSourceSalt).toMatch(/^0x[a-fA-F0-9]{64}$/)
      expect(inboxSalt).toMatch(/^0x[a-fA-F0-9]{64}$/)
    })

    it('should preserve CreateX permissions when preserveCreateXPermissions is true', () => {
      const hyperProverSalt = getContractSalt(guardedSalt, 'HYPER_PROVER', true)

      // First 21 bytes (42 hex chars) should match the guarded salt
      const guardedSaltPrefix = guardedSalt.slice(0, 44) // 0x + 42 chars
      const hyperProverSaltPrefix = hyperProverSalt.slice(0, 44)

      expect(guardedSaltPrefix).toBe(hyperProverSaltPrefix)
      expect(hyperProverSalt).toMatch(/^0x[a-fA-F0-9]{64}$/)
    })

    it('should generate different salt when preserveCreateXPermissions is false', () => {
      const saltWithPermissions = getContractSalt(
        guardedSalt,
        'HYPER_PROVER',
        true,
      )
      const saltWithoutPermissions = getContractSalt(
        guardedSalt,
        'HYPER_PROVER',
        false,
      )

      expect(saltWithPermissions).not.toBe(saltWithoutPermissions)

      // Without permissions, the first 21 bytes should NOT match
      const guardedSaltPrefix = guardedSalt.slice(0, 44)
      const saltWithoutPermissionsPrefix = saltWithoutPermissions.slice(0, 44)

      expect(guardedSaltPrefix).not.toBe(saltWithoutPermissionsPrefix)
    })
  })

  describe('getHyperProverSalt', () => {
    it('should generate HyperProver salt with preserved permissions', () => {
      const hyperProverSalt = getHyperProverSalt(guardedSalt, true)

      // Should preserve first 21 bytes from guarded salt
      const guardedSaltPrefix = guardedSalt.slice(0, 44)
      const hyperProverSaltPrefix = hyperProverSalt.slice(0, 44)

      expect(guardedSaltPrefix).toBe(hyperProverSaltPrefix)
      expect(hyperProverSalt).toMatch(/^0x[a-fA-F0-9]{64}$/)
    })

    it('should generate different salt when preserveCreateXPermissions is false', () => {
      const saltWithPermissions = getHyperProverSalt(guardedSalt, true)
      const saltWithoutPermissions = getHyperProverSalt(guardedSalt, false)

      expect(saltWithPermissions).not.toBe(saltWithoutPermissions)
    })

    it('should be equivalent to getContractSalt with HYPER_PROVER', () => {
      const hyperProverSalt1 = getHyperProverSalt(guardedSalt, true)
      const hyperProverSalt2 = getContractSalt(
        guardedSalt,
        'HYPER_PROVER',
        true,
      )

      expect(hyperProverSalt1).toBe(hyperProverSalt2)
    })
  })

  describe('salt format validation', () => {
    it('should maintain salt format for CreateX compatibility', () => {
      const hyperProverSalt = getHyperProverSalt(guardedSalt, true)

      // Verify the salt is 32 bytes (64 hex chars + 0x)
      expect(hyperProverSalt).toHaveLength(66)
      expect(hyperProverSalt).toMatch(/^0x[a-fA-F0-9]{64}$/)

      // Verify first 20 bytes match deployer address from guarded salt
      const deployerFromGuarded = guardedSalt.slice(0, 42) // 0x + 40 chars
      const deployerFromHyperProver = hyperProverSalt.slice(0, 42)

      expect(deployerFromGuarded).toBe(deployerFromHyperProver)
    })
  })
})
