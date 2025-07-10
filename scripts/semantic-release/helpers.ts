/**
 * @file helpers.ts
 *
 * Provides utility functions and shared helpers for the semantic-release workflow.
 *
 * This module contains common functionality used across different semantic-release
 * lifecycle events, including version handling, logging, package management,
 * and file operations. These utilities ensure consistent behavior and reduce
 * code duplication throughout the release process.
 *
 * Key features:
 * - Standardized logging interface matching semantic-release conventions
 * - Version comparison and manipulation utilities
 * - Package manifest handling and transformation
 * - File system operations specific to the release process
 * - Package distribution and publication helpers
 * - Metadata handling and transformation
 */

import fs from 'fs'
import path from 'path'
import pacote from 'pacote'
import semverUtils from 'semver-utils'
import semver from 'semver'

// Define a logger interface to make it consistent with semantic-release logger
export interface Logger {
  log: (message: string) => void
  error: (message: string) => void
  warn: (message: string) => void
}

/**
 * Fetches information about the latest version of a package with the same major.minor version
 * allowing for comparison with the current version being released to ensure proper versioning.
 *
 * @param packageName - Name of the package to check in the npm registry
 * @param version - Current version being released in semver format
 * @param logger - Logger instance for output messages
 * @returns Object containing the published version and a flag indicating if current version is newer, or null if no published version exists
 *
 * @example
 * // Get latest version info for 'eco-routes' with version '1.2.3'
 * const versionInfo = await fetchLatestPackageVersion('eco-routes', '1.2.3', logger);
 * if (versionInfo && !versionInfo.isNewer) {
 *   throw new Error('Current version is not newer than published version');
 * }
 */
export async function fetchLatestPackageVersion(
  packageName: string,
  version: string,
  logger: Logger,
): Promise<{ version: string; isNewer: boolean } | null> {
  try {
    // Parse the current version to extract major.minor
    const parsedVersion = semverUtils.parse(version)
    if (!parsedVersion) {
      logger.error(`Failed to parse version: ${version}`)
      return null
    }

    const majorMinorVersion = `${parsedVersion.major}.${parsedVersion.minor}`
    logger.log(
      `Checking for existing package ${packageName}@${majorMinorVersion}.x`,
    )

    // Query for the latest package matching the major.minor version
    try {
      const manifest = await pacote.manifest(
        `${packageName}@${majorMinorVersion}.x`,
        {
          // Refresh cache to ensure we get the latest version
          preferOnline: true,
        },
      )

      const publishedVersion = manifest.version
      logger.log(`Found published version: ${publishedVersion}`)

      // Compare if the current version is newer than what's published
      const isNewer = semver.gt(version, publishedVersion)

      return {
        version: publishedVersion,
        isNewer,
      }
    } catch (error) {
      // If the error is 'No matching version found', this might be a new major.minor version
      if ((error as Error).message.includes('No matching version found')) {
        logger.log(
          `No existing package found for ${packageName}@${majorMinorVersion}.x`,
        )
        return null
      }

      throw error
    }
  } catch (error) {
    logger.error(`Error fetching package info: ${(error as Error).message}`)
    return null
  }
}

/**
 * Lists all files in a directory recursively, maintaining relative paths,
 * which is useful for copying entire directory structures while preserving
 * the hierarchy of files.
 *
 * @param dir - Absolute path to the directory to list files from
 * @returns Array of file paths relative to the provided directory
 *
 * @example
 * // Get all files in the contracts directory
 * const files = listFilesRecursively('/path/to/contracts');
 * // Result: ['Contract.sol', 'interfaces/IContract.sol', ...]
 */
export function listFilesRecursively(dir: string): string[] {
  const files: string[] = []

  function traverseDir(currentDir: string, relativePath: string = '') {
    const entries = fs.readdirSync(currentDir, { withFileTypes: true })

    for (const entry of entries) {
      const fullPath = path.join(currentDir, entry.name)
      const relativeFull = path.join(relativePath, entry.name)

      if (entry.isDirectory()) {
        traverseDir(fullPath, relativeFull)
      } else {
        files.push(relativeFull)
      }
    }
  }

  traverseDir(dir)
  return files
}

/**
 * Validates that a string follows proper semantic versioning (semver) formatting rules,
 * ensuring it can be properly processed by deployment scripts and package managers.
 *
 * @param version - Version string to validate (e.g., '1.2.3' or '1.2.3-beta.1')
 * @returns Boolean indicating whether the version is valid according to semver rules
 *
 * @example
 * // Check if a version string is valid
 * if (!isValidVersion('1.2.x')) {
 *   throw new Error('Invalid version format');
 * }
 */
export function isValidVersion(version: string): boolean {
  return !!semver.valid(version)
}

/**
 * Reads and parses the package.json file from the specified directory path,
 * providing access to package metadata, version information, dependencies, and scripts.
 *
 * @param directoryPath - Path to the directory containing package.json
 * @returns Parsed package.json content as a JavaScript object
 *
 * @example
 * // Get package information from the current directory
 * const packageInfo = getPackageInfo('/path/to/project');
 * console.log(`Package name: ${packageInfo.name}, version: ${packageInfo.version}`);
 */
export function getPackageInfo(directoryPath: string): Record<string, any> {
  return JSON.parse(
    fs.readFileSync(path.join(directoryPath, 'package.json'), 'utf-8'),
  )
}
