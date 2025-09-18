// Mock dotenv before importing main module
jest.mock('dotenv', () => ({
  config: jest.fn(),
}))

import { version } from '../sr-version'
import * as updaterModule from '../solidity-version-updater'
import { SemanticContext, SemanticPluginConfig } from '../sr-prepare'

// Mock the solidity-version-updater functions
jest.mock('../solidity-version-updater', () => ({
  updateSolidityVersions: jest.fn().mockReturnValue(3),
  updatePackageJsonVersion: jest.fn(),
  getGitHashShort: jest.fn().mockReturnValue('abc1234'),
}))

describe('Semantic Release Version Function', () => {
  // Test constants
  const testVersion = '1.2.3'
  const testPath = '/test/path'
  const updatedFilesCount = 3

  // Test fixtures
  let context: SemanticContext
  let pluginConfig: SemanticPluginConfig

  beforeEach(() => {
    // Arrange: Reset all mocks
    jest.clearAllMocks()

    // Arrange: Configure mocks with default behavior
    ;(updaterModule.updateSolidityVersions as jest.Mock).mockReturnValue(
      updatedFilesCount,
    )

    // Arrange: Create mock context
    context = {
      nextRelease: {
        version: testVersion,
        gitTag: `v${testVersion}`,
        notes: 'Test release notes',
        type: 'minor',
      },
      logger: {
        log: jest.fn(),
        error: jest.fn(),
        warn: jest.fn(),
      },
      cwd: testPath,
    }

    pluginConfig = {}
  })

  it('should update package.json version (Solidity versions are manually managed)', async () => {
    // Act: Execute the version function
    await version(pluginConfig, context)

    // Assert: Verify updateSolidityVersions was NOT called (manual management)
    expect(updaterModule.updateSolidityVersions).not.toHaveBeenCalled()

    // Assert: Verify updatePackageJsonVersion was called correctly
    expect(updaterModule.updatePackageJsonVersion).toHaveBeenCalledTimes(1)
    expect(updaterModule.updatePackageJsonVersion).toHaveBeenCalledWith(
      testPath,
      testVersion,
      context.logger,
    )

    // Assert: Verify logger messages
    expect(context.logger.log).toHaveBeenCalledWith(
      `Updating version information to ${testVersion}`,
    )
    expect(context.logger.log).toHaveBeenCalledWith(
      `✅ Version information updated successfully to ${testVersion}`,
    )
  })

  it('should skip version updates when no release is detected', async () => {
    // Arrange: Create context without nextRelease
    const contextWithoutRelease: SemanticContext = {
      ...context,
      nextRelease: undefined,
    }

    // Act: Execute the version function
    await version(pluginConfig, contextWithoutRelease)

    // Assert: Verify update functions were not called
    expect(updaterModule.updateSolidityVersions).not.toHaveBeenCalled()
    expect(updaterModule.updatePackageJsonVersion).not.toHaveBeenCalled()

    // Assert: Verify logger message
    expect(contextWithoutRelease.logger.log).toHaveBeenCalledTimes(1)
    expect(contextWithoutRelease.logger.log).toHaveBeenCalledWith(
      'No release detected, skipping version updates',
    )
  })

  it.skip('should throw error when Solidity version update fails (SKIPPED - Solidity versions manually managed)', async () => {
    // This test is skipped because Solidity versions are now manually managed
    // in contracts/libs/Semver.sol and not updated automatically
  })

  it('should throw error when package.json update fails', async () => {
    // Arrange: Mock updatePackageJsonVersion to throw an error
    const errorMessage = 'Failed to update package.json'
    ;(
      updaterModule.updatePackageJsonVersion as jest.Mock
    ).mockImplementationOnce(() => {
      throw new Error(errorMessage)
    })

    // Act & Assert: Execute version function and expect it to throw
    await expect(version(pluginConfig, context)).rejects.toThrow(errorMessage)

    // Assert: Verify error was logged
    expect(context.logger.error).toHaveBeenCalledWith(
      `❌ Failed to update version information: ${errorMessage}`,
    )

    // Assert: Verify updateSolidityVersions was NOT called (manual management)
    expect(updaterModule.updateSolidityVersions).not.toHaveBeenCalled()
  })
})
