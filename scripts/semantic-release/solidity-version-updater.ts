/**
 * @file solidity-version-updater.ts
 *
 * Specialized utilities for managing version information in Solidity smart contracts.
 * This module handles the complex task of updating version identifiers in contract source
 * code to maintain consistency between semantic versions and on-chain version reporting.
 *
 * The version management system implements standardized version interfaces for smart
 * contracts, ensuring that deployed contracts can accurately report their version
 * via on-chain queries. This is essential for protocol governance, security auditing,
 * and ensuring client compatibility with specific contract implementations.
 *
 * Key capabilities:
 * - Recursively scans Solidity files to locate version reporting functions
 * - Pattern-matches on standard version interfaces (ISemver implementation)
 * - Updates version strings with proper semantic versioning format
 * - Embeds Git commit hashes for traceability between source and deployments
 * - Synchronizes version information between package.json and Solidity files
 * - Handles complex regex patterns for reliable version string replacement
 * - Preserves Solidity file structure and formatting during updates
 *
 * These utilities ensure that all deployed contracts implement standardized versioning
 * interfaces and report accurate version information that correlates with the package
 * version and Git commit history.
 */

import * as fs from 'fs'
import * as path from 'path'
import { execSync } from 'child_process'
import { PATHS } from './constants'
import { Logger } from './helpers'
import { getBaseVersion } from '../utils/extract-salt'

/**
 * Gets the short git hash for the current commit, which is used to embed
 * in version strings for traceability between source code and deployed contracts.
 *
 * @returns Short git hash string (typically 7 characters) of the current HEAD commit
 *
 * @example
 * // Get current git commit hash for version string
 * const gitHash = getGitHashShort(); // "abc1234"
 * const fullVersion = `${version}-${gitHash}`; // "1.2.3-abc1234"
 */
export function getGitHashShort(): string {
  return execSync('git rev-parse --short HEAD').toString().trim()
}

/**
 * Updates version information in all Solidity files recursively by scanning for
 * ISemver implementations and updating their version() function return values.
 *
 * This function traverses the contracts directory and its subdirectories to find
 * all Solidity files that implement the ISemver interface (identified by having a
 * version() function). It updates these functions to return the current semantic version
 * along with the git hash in the format "1.2.3-abc1234".
 *
 * @param cwd - Current working directory containing the contracts folder
 * @param version - Semantic version string to set in Solidity files
 * @param logger - Logger instance for output messages and errors
 * @returns Number of Solidity files that were successfully updated
 *
 * @throws Will throw an error if file operations fail or if directory traversal fails
 *
 * @example
 * // Update all Solidity contract versions to 1.2.3
 * const updatedCount = updateSolidityVersions('/project/root', '1.2.3', logger);
 * console.log(`Updated ${updatedCount} contract files`);
 */
export function updateSolidityVersions(
  cwd: string,
  version: string,
  logger: Logger,
): number {
  const contractsDir = path.join(cwd, 'contracts')
  let updatedCount = 0
  const baseVersion = getBaseVersion(version, logger)
  logger.log(
    `Updating Solidity files to base version ${baseVersion} from whole version ${version}-${getGitHashShort()}`,
  )

  // Recursive function to traverse directories and update .sol files
  function updateDirectory(dir: string): void {
    const files = fs.readdirSync(dir)

    files.forEach((file) => {
      const filePath = path.join(dir, file)
      const stat = fs.statSync(filePath)

      if (stat.isDirectory()) {
        // Recursively process subdirectories
        updateDirectory(filePath)
      } else if (filePath.endsWith('.sol')) {
        // Read and update .sol files
        const content = fs.readFileSync(filePath, 'utf8')
        const versionRegex =
          /function version\(\) external pure returns \(string memory\) \{[^}]*\}/

        // Only update if the file has a version function
        if (versionRegex.test(content)) {
          // const newVersionFunction = `function version() external pure returns (string memory) { return "${version}-${gitHash}"; }`
          // Remove git hash as it causes change in bytecode
          const newVersionFunction = `function version() external pure returns (string memory) { return "${baseVersion}"; }`
          const updatedContent = content.replace(
            versionRegex,
            newVersionFunction,
          )

          // Only write if the content actually changed
          if (content !== updatedContent) {
            fs.writeFileSync(filePath, updatedContent, 'utf8')
            logger.log(`Updated version in ${path.relative(cwd, filePath)}`)
            updatedCount++
          }
        }
      }
    })
  }

  // Start processing from the contracts directory
  try {
    updateDirectory(contractsDir)
    logger.log(
      `Successfully updated ${updatedCount} Solidity files with version ${version}`,
    )
    return updatedCount
  } catch (error) {
    logger.error(
      `Error updating Solidity versions: ${(error as Error).message}`,
    )
    throw error
  }
}

/**
 * Updates the version field in the package.json file with the new semantic version.
 * This ensures the npm package and on-chain contracts share the same version number.
 *
 * This function reads the package.json file, updates the version field with the
 * provided semantic version string, and writes the file back with proper formatting.
 * It preserves all other fields and formatting in the package.json file.
 *
 * @param cwd - Current working directory containing the package.json file
 * @param version - Semantic version string to set in package.json
 * @param logger - Logger instance for output messages and errors
 * @returns void
 *
 * @throws Will throw an error if the package.json file cannot be read or written
 *
 * @example
 * // Update package.json version to 1.2.3
 * updatePackageJsonVersion('/project/root', '1.2.3', logger);
 */
export function updatePackageJsonVersion(
  cwd: string,
  version: string,
  logger: Logger,
): void {
  try {
    const packageJsonPath = path.join(cwd, PATHS.PACKAGE_JSON)

    // Read and parse package.json
    const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'))

    // Update version
    packageJson.version = version

    // Write back to file
    fs.writeFileSync(
      packageJsonPath,
      JSON.stringify(packageJson, null, 2) + '\n',
      'utf8',
    )

    logger.log(`Updated version in package.json to ${version}`)
  } catch (error) {
    logger.error(
      `Error updating package.json version: ${(error as Error).message}`,
    )
    throw error
  }
}
