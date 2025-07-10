// Mock dotenv before importing main module
jest.mock('dotenv', () => ({
  config: jest.fn(),
}))

import {
  fetchLatestPackageVersion,
  listFilesRecursively,
  isValidVersion,
  getPackageInfo,
  Logger,
} from '../helpers'
import * as fs from 'fs'
import * as path from 'path'
import pacote from 'pacote'
import semver from 'semver'
import { PACKAGE } from '../constants'

// Mock dependencies
jest.mock('fs', () => ({
  readFileSync: jest.fn(),
  readdirSync: jest.fn(),
  existsSync: jest.fn(),
  mkdirSync: jest.fn(),
}))

jest.mock('path', () => ({
  join: jest.fn((...args) => args.join('/')),
}))

jest.mock('pacote', () => ({
  manifest: jest.fn(),
  extract: jest.fn(),
}))

jest.mock('semver', () => ({
  valid: jest.fn(),
  gt: jest.fn(),
}))

describe('Semantic Release Helpers', () => {
  // Test constants
  const testPackageName = '@eco-foundation/routes'
  const testVersion = '1.2.3'
  const testDir = '/test/dir'

  // Test fixtures
  let mockLogger: Logger

  beforeEach(() => {
    // Arrange: Reset all mocks
    jest.clearAllMocks()

    // Arrange: Create mock logger
    mockLogger = {
      log: jest.fn(),
      error: jest.fn(),
      warn: jest.fn(),
    }
  })

  describe('fetchLatestPackageVersion', () => {
    it('should return version info with isNewer flag when package exists', async () => {
      // Arrange: Setup mocks
      const publishedVersion = '1.2.2'
      ;(pacote.manifest as jest.Mock).mockResolvedValue({
        version: publishedVersion,
      })
      ;(semver.gt as jest.Mock).mockReturnValue(true)

      // Act: Call the function
      const result = await fetchLatestPackageVersion(
        testPackageName,
        testVersion,
        mockLogger,
      )

      // Assert: Check correct result
      expect(result).toEqual({
        version: publishedVersion,
        isNewer: true,
      })

      // Assert: Logger messages
      expect(mockLogger.log).toHaveBeenCalledWith(
        `Checking for existing package ${testPackageName}@1.2.x`,
      )
      expect(mockLogger.log).toHaveBeenCalledWith(
        `Found published version: ${publishedVersion}`,
      )

      // Assert: Pacote was called with correct arguments
      expect(pacote.manifest).toHaveBeenCalledWith(
        `${testPackageName}@1.2.x`,
        expect.any(Object),
      )
    })

    it('should return null when no matching version is found', async () => {
      // Arrange: Setup pacote to throw "No matching version found" error
      ;(pacote.manifest as jest.Mock).mockRejectedValue({
        message: 'No matching version found',
      })

      // Act: Call the function
      const result = await fetchLatestPackageVersion(
        testPackageName,
        testVersion,
        mockLogger,
      )

      // Assert: Check result is null
      expect(result).toBeNull()

      // Assert: Logger messages
      expect(mockLogger.log).toHaveBeenCalledWith(
        `No existing package found for ${testPackageName}@1.2.x`,
      )
    })

    it('should handle version parsing errors', async () => {
      // Arrange: Setup invalid version
      const invalidVersion = 'invalid'

      // Act: Call the function
      const result = await fetchLatestPackageVersion(
        testPackageName,
        invalidVersion,
        mockLogger,
      )

      // Assert: Check result is null
      expect(result).toBeNull()

      // Assert: Error was logged
      expect(mockLogger.error).toHaveBeenCalledWith(
        `Failed to parse version: ${invalidVersion}`,
      )
    })
  })

  // downloadPackage is not exported from helpers.ts

  describe('listFilesRecursively', () => {
    it('should list files recursively', () => {
      // Arrange: Setup mock directories and files
      const rootEntries = [
        { name: 'file1.txt', isDirectory: () => false },
        { name: 'dir1', isDirectory: () => true },
      ]

      const dir1Entries = [
        { name: 'file2.txt', isDirectory: () => false },
        { name: 'nested', isDirectory: () => true },
      ]

      const nestedEntries = [{ name: 'file3.txt', isDirectory: () => false }]

      // Setup readdirSync to return different entries based on path
      ;(fs.readdirSync as jest.Mock).mockImplementation((dir) => {
        if (dir === testDir) return rootEntries
        if (dir === `${testDir}/dir1`) return dir1Entries
        if (dir === `${testDir}/dir1/nested`) return nestedEntries
        return []
      })

      // Act: Call the function
      const result = listFilesRecursively(testDir)

      // Assert: Check files are listed correctly
      expect(result).toContain('/file1.txt')
      expect(result).toContain('/dir1/file2.txt')
      expect(result).toContain('/dir1/nested/file3.txt')
    })
  })

  describe('isValidVersion', () => {
    it('should return true for valid semver', () => {
      // Arrange: Setup semver.valid to return a value
      ;(semver.valid as jest.Mock).mockReturnValue(testVersion)

      // Act: Call the function
      const result = isValidVersion(testVersion)

      // Assert: Result is true
      expect(result).toBe(true)
      expect(semver.valid).toHaveBeenCalledWith(testVersion)
    })

    it('should return false for invalid semver', () => {
      // Arrange: Setup semver.valid to return null
      ;(semver.valid as jest.Mock).mockReturnValue(null)

      // Act: Call the function
      const result = isValidVersion('invalid')

      // Assert: Result is false
      expect(result).toBe(false)
    })
  })

  // getTypeScriptPackageName is not exported from helpers.ts

  describe('getPackageInfo', () => {
    it('should read and parse package.json', () => {
      // Arrange: Mock package.json content
      const packageJson = { name: testPackageName, version: testVersion }
      ;(fs.readFileSync as jest.Mock).mockReturnValue(
        JSON.stringify(packageJson),
      )
      ;(path.join as jest.Mock).mockReturnValue(`${testDir}/package.json`)

      // Act: Call the function
      const result = getPackageInfo(testDir)

      // Assert: Check correct package info returned
      expect(result).toEqual(packageJson)
      expect(fs.readFileSync).toHaveBeenCalledWith(
        `${testDir}/package.json`,
        'utf-8',
      )
    })
  })
})
