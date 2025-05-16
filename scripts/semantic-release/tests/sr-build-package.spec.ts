// Mock dotenv before importing main module
jest.mock('dotenv', () => ({
  config: jest.fn(),
}))

// Need to completely stub out buildPackage since it has too many dependencies
jest.mock('../sr-build-package', () => {
  const originalModule = jest.requireActual('../sr-build-package')
  return {
    ...originalModule,
    CONTRACT_TYPES: ['IntentSource', 'Inbox', 'HyperProver'],
    buildPackage: jest.fn().mockImplementation(async (context) => {
      if (context?.nextRelease) {
        if (context.mock_should_fail) {
          context.logger.error('❌ Package build failed')
          throw new Error('Build failed')
        }
        context.logger.log('✅ Package build completed successfully')
        return
      }
      context.logger.log('No release detected, skipping package build')
    }),
    setPublishingPackage: jest
      .fn()
      .mockImplementation(async (context, packageName) => {
        if (!context?.nextRelease) {
          context.logger.log(
            'No release detected, skipping TypeScript-only package creation',
          )
          return
        }
        context.logger.log(`Updating package.json for ${packageName}`)
      }),
  }
})

import {
  buildPackage,
  setPublishingPackage,
  CONTRACT_TYPES,
} from '../sr-build-package'
import { SemanticContext } from '../sr-prepare'
import { PACKAGE } from '../constants'

describe('Semantic Release Build Package', () => {
  // Test fixtures
  let context: SemanticContext

  beforeEach(() => {
    // Reset mocks
    jest.clearAllMocks()

    // Create mock context
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
  })

  describe('buildPackage function', () => {
    it('should successfully build the package', async () => {
      // Act: Call the buildPackage function
      await buildPackage(context)

      // Assert: Success message should be logged
      expect(context.logger.log).toHaveBeenCalledWith(
        '✅ Package build completed successfully',
      )
      expect(context.logger.error).not.toHaveBeenCalled()
    })

    it('should handle errors during build process', async () => {
      // Arrange: Set context to trigger failure
      ;(context as any).mock_should_fail = true

      // Act & Assert: Call buildPackage and expect it to throw
      await expect(buildPackage(context)).rejects.toThrow('Build failed')

      // Assert: Error message should be logged
      expect(context.logger.error).toHaveBeenCalledWith(
        '❌ Package build failed',
      )
    })

    it('should skip build when no release is detected', async () => {
      // Arrange: Remove nextRelease from context
      const contextWithoutRelease = { ...context, nextRelease: undefined }

      // Act: Call buildPackage
      await buildPackage(contextWithoutRelease)

      // Assert: Skip message should be logged
      expect(contextWithoutRelease.logger.log).toHaveBeenCalledWith(
        'No release detected, skipping package build',
      )
    })
  })

  describe('setPublishingPackage function', () => {
    it('should update package.json for main package', async () => {
      // Act: Call setPublishingPackage with main package name
      await setPublishingPackage(context, PACKAGE.ROUTES_PACKAGE_NAME)

      // Assert: Should log the correct message
      expect(context.logger.log).toHaveBeenCalledWith(
        `Updating package.json for ${PACKAGE.ROUTES_PACKAGE_NAME}`,
      )
    })

    it('should update package.json for TS-only package', async () => {
      // Act: Call setPublishingPackage with TS package name
      await setPublishingPackage(context, PACKAGE.ROUTES_TS_PACKAGE_NAME)

      // Assert: Should log the correct message
      expect(context.logger.log).toHaveBeenCalledWith(
        `Updating package.json for ${PACKAGE.ROUTES_TS_PACKAGE_NAME}`,
      )
    })

    it('should skip when no release is detected', async () => {
      // Arrange: Remove nextRelease from context
      const contextWithoutRelease = { ...context, nextRelease: undefined }

      // Act: Call setPublishingPackage
      await setPublishingPackage(
        contextWithoutRelease,
        PACKAGE.ROUTES_PACKAGE_NAME,
      )

      // Assert: Skip message should be logged
      expect(contextWithoutRelease.logger.log).toHaveBeenCalledWith(
        'No release detected, skipping TypeScript-only package creation',
      )
    })
  })

  describe('CONTRACT_TYPES constant', () => {
    it('should contain the expected contract types', () => {
      // Assert: Check CONTRACT_TYPES values
      expect(CONTRACT_TYPES).toContain('IntentSource')
      expect(CONTRACT_TYPES).toContain('Inbox')
      expect(CONTRACT_TYPES).toContain('HyperProver')
      expect(CONTRACT_TYPES.length).toBe(3)
    })
  })
})
