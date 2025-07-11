import { prepare, SemanticContext, SemanticPluginConfig } from '../sr-prepare'
import * as buildPackageModule from '../sr-build-package'
import * as deployModule from '../sr-deploy-contracts'
import * as verifyModule from '../verify-contracts'
import { exec } from 'child_process'
import * as singletonFactoryModule from '../sr-singleton-factory'

// Mock child_process.exec and execSync
jest.mock('child_process', () => ({
  exec: jest.fn((cmd, callback) => {
    if (callback) callback(null, { stdout: 'success', stderr: '' })
    return {
      stdout: { on: jest.fn() },
      stderr: { on: jest.fn() },
      on: jest.fn(),
    }
  }),
  execSync: jest.fn(() => Buffer.from('abc1234')),
}))

// Mock the modules
jest.mock('../sr-build-package', () => ({
  buildPackage: jest.fn().mockResolvedValue(undefined),
  setPublishingPackage: jest.fn(),
}))

jest.mock('../sr-deploy-contracts', () => ({
  deployRoutesContracts: jest.fn().mockResolvedValue(undefined),
}))

jest.mock('../verify-contracts', () => ({
  verifyContracts: jest.fn().mockResolvedValue(undefined),
}))

// Mock the sr-singleton-factory module
jest.mock('../sr-singleton-factory', () => ({
  deploySingletonFactory: jest.fn().mockResolvedValue(undefined),
}))

// Mock environment variables
jest.mock('../../utils/envUtils', () => ({
  validateEnvVariables: jest.fn(),
}))

// Mock fs
jest.mock('fs', () => ({
  readFileSync: jest.fn(() => JSON.stringify({ name: 'test-package' })),
  existsSync: jest.fn(() => true),
  writeFileSync: jest.fn(),
  unlinkSync: jest.fn(),
  mkdirSync: jest.fn(),
  readdirSync: jest.fn(() => []),
  copyFileSync: jest.fn(),
  statSync: jest.fn(() => ({ isDirectory: () => false })),
}))

describe('Prepare function', () => {
  // Extracted test variables to avoid duplication
  const testVersion = '0.0.3'
  const testPackageName = 'test-package'

  // Fixtures for common test setup
  let context: SemanticContext
  let pluginConfig: SemanticPluginConfig

  beforeEach(() => {
    // Arrange: Reset all mocks
    jest.clearAllMocks()

    // Arrange: Create mock context
    context = {
      nextRelease: {
        version: testVersion,
        gitTag: `v${testVersion}`,
        notes: 'Test release',
        type: 'patch',
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

  // disabling for now,need to fix the api keys for verify
  it.skip('should call all required functions during prepare phase', async () => {
    // Act: Execute the prepare function
    await prepare(pluginConfig, context)

    // Assert: Verify buildHardhat was called (exec was called for clean, build, and forge build commands)
    expect(exec).toHaveBeenCalledTimes(3)
    expect(exec).toHaveBeenCalledWith('npm run clean', expect.any(Function))
    expect(exec).toHaveBeenCalledWith(
      'env COMPILE_MODE=production npm run build',
      expect.any(Function),
    )
    expect(exec).toHaveBeenCalledWith('forge build', expect.any(Function))

    // Assert: Verify deployRoutesContracts was called
    expect(deployModule.deployRoutesContracts).toHaveBeenCalledTimes(1)
    expect(deployModule.deployRoutesContracts).toHaveBeenCalledWith(
      context,
      testPackageName,
    )

    // Assert: Verify verifyContracts was called
    expect(verifyModule.verifyContracts).toHaveBeenCalledTimes(1)
    expect(verifyModule.verifyContracts).toHaveBeenCalledWith(context)

    // Assert: Verify buildPackage was called
    expect(buildPackageModule.buildPackage).toHaveBeenCalledTimes(1)
    expect(buildPackageModule.buildPackage).toHaveBeenCalledWith(context)

    // Assert: Verify logger was called with expected messages
    expect(context.logger.log).toHaveBeenCalledWith(
      `Preparing to deploy contracts for version ${testVersion}`,
    )
    expect(context.logger.log).toHaveBeenCalledWith(
      `Deploying contracts for package: ${testPackageName}`,
    )
    expect(context.logger.log).toHaveBeenCalledWith(
      `Contracts deployed for version ${testVersion}`,
    )
    expect(context.logger.log).toHaveBeenCalledWith(
      `Verifying deployed contracts`,
    )
    expect(context.logger.log).toHaveBeenCalledWith(
      `Contracts verified for version ${testVersion}`,
    )
    expect(context.logger.log).toHaveBeenCalledWith(`Building main package`)
    expect(context.logger.log).toHaveBeenCalledWith(
      `Main package built for version ${testVersion}`,
    )
  })

  it('should skip deployment when no release is detected', async () => {
    // Arrange: Create context without nextRelease
    const contextWithoutRelease: SemanticContext = {
      ...context,
      nextRelease: undefined,
    }

    // Act: Execute the prepare function
    await prepare(pluginConfig, contextWithoutRelease)

    // Assert: Verify no functions were called
    expect(exec).not.toHaveBeenCalled()
    expect(deployModule.deployRoutesContracts).not.toHaveBeenCalled()
    expect(verifyModule.verifyContracts).not.toHaveBeenCalled()
    expect(buildPackageModule.buildPackage).not.toHaveBeenCalled()

    // Assert: Verify logger was called with skip message
    expect(contextWithoutRelease.logger.log).toHaveBeenCalledTimes(2)
    expect(contextWithoutRelease.logger.log).toHaveBeenCalledWith(
      'No release detected, skipping contract deployment',
    )
  })
})
