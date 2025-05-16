import { publish } from '../sr-publish'
import * as buildPackageModule from '../sr-build-package'
import { exec } from 'child_process'
import { SemanticContext } from '../sr-prepare'
import { ENV_VARS, PACKAGE } from '../constants'

// Mock child_process.exec
jest.mock('child_process', () => ({
  exec: jest.fn((cmd, options, callback) => {
    if (callback) callback(null, { stdout: 'success', stderr: '' })
    return {
      stdout: { on: jest.fn() },
      stderr: { on: jest.fn() },
      on: jest.fn().mockImplementation((event, handler) => {
        if (event === 'close') {
          handler(0) // Simulate successful completion
        }
        return { on: jest.fn() }
      }),
    }
  }),
}))

// Mock fs
jest.mock('fs', () => ({
  existsSync: jest.fn(() => true),
  writeFileSync: jest.fn(),
  readFileSync: jest.fn(() => '{}'),
  mkdirSync: jest.fn(),
}))

// Mock sr-build-package
jest.mock('../sr-build-package', () => ({
  setPublishingPackage: jest.fn(),
}))

// Mock getBuildDirPath
jest.mock('../constants', () => {
  const originalModule = jest.requireActual('../constants')
  return {
    ...originalModule,
    getBuildDirPath: jest.fn(() => '/test/build/path'),
    PACKAGE: {
      ROUTES_PACKAGE_NAME: '@eco-foundation/routes',
      ROUTES_TS_PACKAGE_NAME: '@eco-foundation/routes-ts',
    },
    ENV_VARS: {
      CI: 'CI',
      NOT_DRY_RUN: 'NOT_DRY_RUN',
    },
  }
})

// Mock console methods
const originalConsoleLog = console.log
const mockConsoleLog = jest.fn()

describe('sr-publish', () => {
  let context: SemanticContext
  let pluginConfig: any
  let processEnvBackup: NodeJS.ProcessEnv

  beforeEach(() => {
    // Save original process.env
    processEnvBackup = { ...process.env }

    // Reset mocks
    jest.clearAllMocks()
    console.log = mockConsoleLog

    // Create test context
    context = {
      nextRelease: {
        version: '1.0.0',
        gitTag: 'v1.0.0',
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
  })

  afterEach(() => {
    // Restore original process.env
    process.env = processEnvBackup
    console.log = originalConsoleLog
  })

  describe('publish function', () => {
    it('should publish packages when not in dry run mode', async () => {
      // Set environment to trigger actual publishing
      process.env[ENV_VARS.CI] = 'true'

      await publish(pluginConfig, context)

      // Should call setPublishingPackage for both packages
      expect(buildPackageModule.setPublishingPackage).toHaveBeenCalledTimes(
        Object.keys(PACKAGE).length,
      )
      expect(buildPackageModule.setPublishingPackage).toHaveBeenCalledWith(
        context,
        PACKAGE.ROUTES_PACKAGE_NAME,
      )
      expect(buildPackageModule.setPublishingPackage).toHaveBeenCalledWith(
        context,
        PACKAGE.ROUTES_TS_PACKAGE_NAME,
      )

      // Should execute yarn publish
      expect(exec).toHaveBeenCalledTimes(2)
      expect(exec).toHaveBeenCalledWith(
        'yarn publish --tag latest',
        expect.objectContaining({
          cwd: '/test/build/path',
        }),
        expect.any(Function),
      )

      // Should log successful publish
      expect(context.logger.log).toHaveBeenCalledWith(
        'Package @eco-foundation/routes@1.0.0 published successfully',
      )
      expect(context.logger.log).toHaveBeenCalledWith(
        'Package @eco-foundation/routes-ts@1.0.0 published successfully',
      )
    })

    it('should skip publishing in dry run mode', async () => {
      // Set environment to trigger dry run
      process.env[ENV_VARS.CI] = 'false'
      process.env[ENV_VARS.NOT_DRY_RUN] = 'false'

      await publish(pluginConfig, context)

      // Should still call setPublishingPackage
      expect(buildPackageModule.setPublishingPackage).toHaveBeenCalledTimes(2)

      // Should NOT execute yarn publish
      expect(exec).not.toHaveBeenCalled()

      // Should log dry run messages
      expect(context.logger.log).toHaveBeenCalledWith(
        'DRY RUN: Skipping actual npm publish. Would have published packages to npm.',
      )
      expect(context.logger.log).toHaveBeenCalledWith(
        'DRY RUN: Not really publishing: @eco-foundation/routes@1.0.0',
      )
      expect(context.logger.log).toHaveBeenCalledWith(
        'Package @eco-foundation/routes@1.0.0 would be published successfully',
      )
    })

    it('should use channel from context as the npm tag', async () => {
      // Set environment to trigger actual publishing
      process.env[ENV_VARS.CI] = 'true'

      // Set context with channel
      const channelContext = {
        ...context,
        nextRelease: {
          ...context.nextRelease!,
          version: '1.0.0',
          channel: 'beta',
        },
      }

      await publish(pluginConfig, channelContext)

      // Should execute yarn publish with beta tag from the channel
      expect(exec).toHaveBeenCalledTimes(2)
      expect(exec).toHaveBeenCalledWith(
        'yarn publish --tag beta',
        expect.any(Object),
        expect.any(Function),
      )
    })

    it('should throw and log error if publishing fails', async () => {
      // Set environment to trigger actual publishing
      process.env[ENV_VARS.CI] = 'true'

      // Mock exec to fail
      ;(exec as any as jest.Mock).mockImplementationOnce(() => {
        throw new Error('Publish failed')
      })

      await expect(publish(pluginConfig, context)).rejects.toThrow(
        'Publish failed',
      )

      // Should log error
      expect(context.logger.error).toHaveBeenCalledWith(
        '❌ Package publish failed',
      )
      expect(context.logger.error).toHaveBeenCalledWith('Publish failed')
    })

    it('should throw error if dist directory does not exist', async () => {
      // Set environment to trigger actual publishing
      process.env[ENV_VARS.CI] = 'true'

      // Mock fs.existsSync to return false
      const fs = require('fs')
      fs.existsSync.mockReturnValueOnce(false)

      await expect(publish(pluginConfig, context)).rejects.toThrow(
        'Compilation failed: dist directory not found at',
      )
    })
  })

  describe('shouldWePublish function', () => {
    it('should return true when CI is true', () => {
      process.env[ENV_VARS.CI] = 'true'
      process.env[ENV_VARS.NOT_DRY_RUN] = 'false'

      const result = publish(pluginConfig, context)

      // Check that we're not in dry run mode
      expect(context.logger.log).not.toHaveBeenCalledWith(
        'DRY RUN: Skipping actual npm publish. Would have published packages to npm.',
      )
    })

    it('should return true when NOT_DRY_RUN is true', () => {
      process.env[ENV_VARS.CI] = 'false'
      process.env[ENV_VARS.NOT_DRY_RUN] = 'true'

      const result = publish(pluginConfig, context)

      // Check that we're not in dry run mode
      expect(context.logger.log).not.toHaveBeenCalledWith(
        'DRY RUN: Skipping actual npm publish. Would have published packages to npm.',
      )
    })

    it('should return false when neither CI nor NOT_DRY_RUN is true', () => {
      process.env[ENV_VARS.CI] = 'false'
      process.env[ENV_VARS.NOT_DRY_RUN] = 'false'

      const result = publish(pluginConfig, context)

      // Check that we are in dry run mode
      expect(context.logger.log).toHaveBeenCalledWith(
        'DRY RUN: Skipping actual npm publish. Would have published packages to npm.',
      )
    })

    it('should log appropriate dry run messages', () => {
      process.env[ENV_VARS.CI] = 'false'
      process.env[ENV_VARS.NOT_DRY_RUN] = 'false'

      // Call directly to capture console logs
      const exportedModule = require('../sr-publish')
      const result = exportedModule.shouldWePublish('2.0.0')

      // Verify the result is false
      expect(result).toBe(false)

      // Check console logs
      expect(mockConsoleLog).toHaveBeenCalledWith(
        'DRY RUN: Skipping actual npm publish. Would have published packages to npm.',
      )
      expect(mockConsoleLog).toHaveBeenCalledWith(
        'Would publish: @eco-foundation/routes@2.0.0',
      )
      expect(mockConsoleLog).toHaveBeenCalledWith(
        'Would publish: @eco-foundation/routes-ts@2.0.0',
      )
      expect(mockConsoleLog).toHaveBeenCalledWith(
        expect.stringContaining('Not publishing. Set'),
      )
    })
  })
})
