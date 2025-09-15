// Mock dotenv before importing main module
jest.mock('dotenv', () => ({
  config: jest.fn(),
}))

import { verifyConditions } from '../sr-verify-conditions'
import * as helpers from '../helpers'
import * as fs from 'fs'
import * as path from 'path'
import { SemanticContext, SemanticPluginConfig } from '../sr-prepare'
import { ENV_VARS, PATHS } from '../constants'

// Mock the fs module
jest.mock('fs', () => ({
  existsSync: jest.fn(() => true),
  readFileSync: jest.fn(() => JSON.stringify({ name: 'test-package' })),
}))

// Mock the path module
jest.mock('path', () => ({
  join: jest.fn((...args) => args.join('/')),
}))

// Mock the helpers module
jest.mock('../helpers', () => ({
  fetchLatestPackageVersion: jest.fn(),
  getPackageInfo: jest.fn(() => ({ name: 'test-package' })),
  isValidVersion: jest.fn(() => true),
}))

describe('Verify Conditions Function', () => {
  // Extracted test constants
  const testVersion = '1.0.0'
  const testPackageName = 'test-package'
  const requiredEnvVars = [
    ENV_VARS.PRIVATE_KEY,
    ENV_VARS.ALCHEMY_API_KEY,
    ENV_VARS.NPM_TOKEN,
  ]

  // Test fixtures
  let context: SemanticContext
  let pluginConfig: SemanticPluginConfig
  let processEnvBackup: NodeJS.ProcessEnv

  beforeEach(() => {
    // Arrange: Save original process.env
    processEnvBackup = { ...process.env }

    // Arrange: Setup environment variables for testing
    requiredEnvVars.forEach((varName) => {
      process.env[varName] = 'test-value'
    })

    // Arrange: Reset all mocks
    jest.clearAllMocks()

    // Arrange: Create test context
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
      cwd: '/test/path',
    }

    pluginConfig = {}

    // Arrange: Setup default mock implementations
    ;(helpers.fetchLatestPackageVersion as jest.Mock).mockResolvedValue({
      version: '0.9.0', // Previous version
      isNewer: true, // Current version is newer
    })
  })

  afterEach(() => {
    // Clean up: Restore process.env
    process.env = processEnvBackup
  })

  it('should pass verification when all conditions are met', async () => {
    // Act: Call verifyConditions function
    await verifyConditions(pluginConfig, context)

    // Assert: Check proper methods were called
    expect(fs.existsSync).toHaveBeenCalled()
    expect(fs.readFileSync).toHaveBeenCalled()
    expect(helpers.isValidVersion).toHaveBeenCalledWith(testVersion)
    expect(helpers.fetchLatestPackageVersion).toHaveBeenCalledWith(
      testPackageName,
      testVersion,
      context.logger,
    )

    // Assert: Check logger messages
    expect(context.logger.log).toHaveBeenCalledWith(
      'Verifying conditions for eco-routes release...',
    )
    expect(context.logger.log).toHaveBeenCalledWith('Version validation passed')
    expect(context.logger.log).toHaveBeenCalledWith(
      '✅ All conditions verified successfully',
    )
  })

  it('should throw error when package.json is not found', async () => {
    // Arrange: Mock fs.existsSync to return false
    ;(fs.existsSync as jest.Mock).mockReturnValueOnce(false)

    // Act & Assert: Should throw error about missing package.json
    await expect(verifyConditions(pluginConfig, context)).rejects.toThrow(
      'package.json not found at',
    )

    // Assert: Check proper methods were called
    expect(fs.existsSync).toHaveBeenCalled()
    expect(fs.readFileSync).not.toHaveBeenCalled()
  })

  it('should throw error when package.json is missing name field', async () => {
    // Arrange: Mock readFileSync to return package without name
    ;(fs.readFileSync as jest.Mock).mockReturnValueOnce(JSON.stringify({}))

    // Act & Assert: Should throw error about missing name field
    await expect(verifyConditions(pluginConfig, context)).rejects.toThrow(
      'Invalid package.json: missing "name" field',
    )
  })

  it('should throw error when required environment variables are missing', async () => {
    // Arrange: Remove required environment variables
    delete process.env[ENV_VARS.PRIVATE_KEY]
    delete process.env[ENV_VARS.NPM_TOKEN]

    // Act & Assert: Should throw error about missing environment variables
    await expect(verifyConditions(pluginConfig, context)).rejects.toThrow(
      'Missing required environment variables:',
    )
  })

  it('should throw error when version format is invalid', async () => {
    // Arrange: Mock isValidVersion to return false
    ;(helpers.isValidVersion as jest.Mock).mockReturnValueOnce(false)

    // Act & Assert: Should throw error about invalid version format
    await expect(verifyConditions(pluginConfig, context)).rejects.toThrow(
      'Invalid version format:',
    )
  })

  it('should throw error when version is not newer than published version', async () => {
    // Arrange: Mock fetchLatestPackageVersion to indicate version is not newer
    ;(helpers.fetchLatestPackageVersion as jest.Mock).mockResolvedValueOnce({
      version: '1.0.1', // Higher version already published
      isNewer: false, // Current version is not newer
    })

    // Act & Assert: Should throw error about version not being newer
    await expect(verifyConditions(pluginConfig, context)).rejects.toThrow(
      'Version 1.0.0 is not newer than already published version 1.0.1',
    )
  })

  it('should skip version check when nextRelease is not provided', async () => {
    // Arrange: Create context without nextRelease
    const contextWithoutRelease = {
      ...context,
      nextRelease: undefined,
    }

    // Act: Call verifyConditions function
    await verifyConditions(pluginConfig, contextWithoutRelease)

    // Assert: Should not call version-related helpers
    expect(helpers.isValidVersion).not.toHaveBeenCalled()
    expect(helpers.fetchLatestPackageVersion).not.toHaveBeenCalled()

    // Assert: Should still log success message
    expect(contextWithoutRelease.logger.log).toHaveBeenCalledWith(
      '✅ All conditions verified successfully',
    )
  })
})
