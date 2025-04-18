/**
 * @file solidity-version-updater.ts
 *
 * Utilities for updating version information in Solidity files and package.json.
 * This functionality is extracted from ProtocolVersion.ts and adapted
 * for use as part of the semantic-release lifecycle.
 *
 * Key functions:
 * - updateSolidityVersions: Recursively finds and updates version() functions in Solidity files
 * - updatePackageJsonVersion: Updates the version in package.json
 * - getGitHashShort: Gets the current git commit hash for embedding in versions
 *
 * For Solidity files, it looks for the standard pattern function version() external pure returns (string memory)
 * and updates the implementation to return the new semantic version with git hash.
 */

import * as fs from 'fs'
import * as path from 'path'
import { execSync } from 'child_process'
import { PATHS } from './constants'
import { Logger } from './helpers'

/**
 * Gets short git hash for the current commit
 * @returns Short git hash
 */
export function getGitHashShort(): string {
  return execSync('git rev-parse --short HEAD').toString().trim()
}

/**
 * Updates version information in all Solidity files recursively
 *
 * This function scans the contracts directory and updates any Solidity files
 * that have a version() function to return the current semantic version
 * along with the git hash.
 *
 * @param cwd - Current working directory
 * @param version - Version to set in Solidity files
 * @param logger - Logger for output messages
 * @returns Number of files that were updated
 */
export function updateSolidityVersions(
  cwd: string,
  version: string,
  logger: Logger,
): number {
  const contractsDir = path.join(cwd, 'contracts')
  const gitHash = getGitHashShort()
  let updatedCount = 0

  logger.log(`Updating Solidity files to version ${version}-${gitHash}`)

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
          const newVersionFunction = `function version() external pure returns (string memory) { return "${version}-${gitHash}"; }`
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
      `Successfully updated ${updatedCount} Solidity files with version ${version}-${gitHash}`,
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
 * Updates the version in package.json file
 *
 * @param cwd - Current working directory
 * @param version - Version to set in package.json
 * @param logger - Logger for output messages
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
