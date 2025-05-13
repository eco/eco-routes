import { getGitHash, getGitHashShort } from '../gitUtils'
import { execSync } from 'child_process'

// Mock child_process.execSync
jest.mock('child_process', () => ({
  execSync: jest.fn(),
}))

describe('gitUtils', () => {
  // Store original execSync implementation
  const mockExecSync = execSync as jest.Mock

  beforeEach(() => {
    // Clear mock calls before each test
    jest.clearAllMocks()
  })

  describe('getGitHash function', () => {
    it('should execute git rev-parse HEAD command', () => {
      // Arrange
      mockExecSync.mockReturnValue('abcdef1234567890\n')

      // Act
      const result = getGitHash()

      // Assert
      expect(mockExecSync).toHaveBeenCalledWith('git rev-parse HEAD')
    })

    it('should return the trimmed git hash', () => {
      // Arrange
      mockExecSync.mockReturnValue('abcdef1234567890\n')

      // Act
      const result = getGitHash()

      // Assert
      expect(result).toBe('abcdef1234567890')
    })

    it('should handle errors from git command', () => {
      // Arrange
      mockExecSync.mockImplementation(() => {
        throw new Error('git command failed')
      })

      // Act & Assert
      expect(() => getGitHash()).toThrow('git command failed')
    })
  })

  describe('getGitHashShort function', () => {
    it('should execute git rev-parse --short HEAD command', () => {
      // Arrange
      mockExecSync.mockReturnValue('abcdef1\n')

      // Act
      const result = getGitHashShort()

      // Assert
      expect(mockExecSync).toHaveBeenCalledWith('git rev-parse --short HEAD')
    })

    it('should return the trimmed short git hash', () => {
      // Arrange
      mockExecSync.mockReturnValue('abcdef1\n')

      // Act
      const result = getGitHashShort()

      // Assert
      expect(result).toBe('abcdef1')
    })

    it('should handle errors from git command', () => {
      // Arrange
      mockExecSync.mockImplementation(() => {
        throw new Error('git command failed')
      })

      // Act & Assert
      expect(() => getGitHashShort()).toThrow('git command failed')
    })
  })
})
