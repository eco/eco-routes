import { determineSalts } from '../extract-salt'
import { keccak256, toHex } from 'viem'

// Mock viem's keccak256 and toHex functions
jest.mock('viem', () => ({
  keccak256: jest.fn((value) => `keccak256(${value})`),
  toHex: jest.fn((value) => `toHex(${value})`),
}))

describe('extract-salt', () => {
  // Create a mock logger
  const mockLogger = {
    log: jest.fn(),
    error: jest.fn(),
    warn: jest.fn(),
  }

  beforeEach(() => {
    // Clear mock calls before each test
    jest.clearAllMocks()
  })

  describe('determineSalts function', () => {
    it('should extract major and minor version components correctly', async () => {
      // Arrange
      const version = '1.2.3'

      // Act
      await determineSalts(version, mockLogger)

      // Assert - check that toHex was called with the correct version base
      expect(toHex).toHaveBeenCalledWith('1.2')
      expect(toHex).toHaveBeenCalledWith('1.2-preprod')
    })

    it('should calculate production and pre-production salts using keccak256', async () => {
      // Arrange
      const version = '3.4.5'

      // Act
      await determineSalts(version, mockLogger)

      // Assert
      expect(keccak256).toHaveBeenCalledWith('toHex(3.4)')
      expect(keccak256).toHaveBeenCalledWith('toHex(3.4-preprod)')
    })

    it('should return both production and pre-production salts', async () => {
      // Arrange
      const version = '2.0.1'

      // Act
      const result = await determineSalts(version, mockLogger)

      // Assert
      expect(result).toHaveProperty('rootSalt')
      expect(result).toHaveProperty('preprodRootSalt')
      expect(result.rootSalt).toBe('keccak256(toHex(2.0))')
      expect(result.preprodRootSalt).toBe('keccak256(toHex(2.0-preprod))')
    })

    it('should log appropriate messages during salt calculation', async () => {
      // Arrange
      const version = '5.6.7'

      // Act
      await determineSalts(version, mockLogger)

      // Assert
      expect(mockLogger.log).toHaveBeenCalledWith(
        'major/minor version (5.6), calculating salt',
      )
      expect(mockLogger.log).toHaveBeenCalledWith(
        expect.stringContaining('Using salt for production:'),
      )
      expect(mockLogger.log).toHaveBeenCalledWith(
        expect.stringContaining('Using salt for pre-production:'),
      )
    })

    it('should handle version strings with multiple dots correctly', async () => {
      // Arrange
      const version = '1.2.3-beta.4'

      // Act
      const result = await determineSalts(version, mockLogger)

      // Assert
      expect(toHex).toHaveBeenCalledWith('1.2')
      expect(result.rootSalt).toBe('keccak256(toHex(1.2))')
    })
  })
})
