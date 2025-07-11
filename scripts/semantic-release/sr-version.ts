/**
 * @file sr-version.ts
 *
 * Manages version information updates for npm packages in the semantic-release process.
 *
 * NOTE: Solidity contract versions are now manually managed in contracts/libs/Semver.sol
 * and are NOT automatically updated by this script. This approach provides better control
 * over contract versioning and avoids potential issues with automated version updates
 * affecting deployed smart contracts.
 *
 * The version module handles:
 * 1. Updating the semantic version in package.json for npm publishing
 * 2. Manual management note: Solidity versions must be updated manually in contracts/libs/Semver.sol
 *
 * Key responsibilities:
 * 1. Updating the semantic version in package.json for npm publishing
 * 2. Logging version update activities for traceability
 * 3. Error handling for version update failures
 *
 * For Solidity contract versions:
 * - Contract versions are manually set in contracts/libs/Semver.sol
 * - This ensures explicit control over on-chain version reporting
 * - Developers must manually update the version() function when needed
 * - Current version in Semver.sol should be kept in sync with major releases
 */

import { SemanticContext, SemanticPluginConfig } from './sr-prepare'
import { updatePackageJsonVersion } from './solidity-version-updater'
import dotenv from 'dotenv'
dotenv.config()

/**
 * Updates version information in all relevant files across the codebase.
 *
 * This function implements the "version" step in the semantic-release lifecycle,
 * which runs after analyzeCommits (to determine the next version) and before
 * prepare (which builds and deploys the contracts). It ensures consistent versioning
 * between package.json and Solidity contract implementations.
 *
 * The function handles:
 * 1. Determining the appropriate version from semantic-release or environment variables
 * 2. Updating the version in package.json for npm publishing
 * 3. Updating Semver.sol implementations in Solidity contracts to report the correct version
 * 4. Logging all version updates for traceability
 *
 * @param pluginConfig - Plugin configuration options from semantic-release
 * @param context - Semantic release context with version, logger, and environment information
 * @returns Promise that resolves when all version updates are complete
 *
 * @throws Will throw an error if any file updates fail
 */
export async function version(
  pluginConfig: SemanticPluginConfig,
  context: SemanticContext,
): Promise<void> {
  const { nextRelease, logger, cwd } = context

  if (!nextRelease) {
    logger.log('No release detected, skipping version updates')
    return
  }

  // Use the custom RELEASE_VERSION environment variable if available

  const version = nextRelease.version || process.env.RELEASE_VERSION
  // Update the version if using a custom one
  if (!version) {
    throw new Error(
      'No version provided. Please set the RELEASE_VERSION or provide a version in the context.',
    )
  }
  logger.log(`Updating version information to ${version}`)

  try {
    // // 1. Update version in Solidity files
    // const updatedFiles = updateSolidityVersions(cwd, version, logger)
    // logger.log(`Updated version in ${updatedFiles} Solidity files`)

    // 2. Update version in package.json
    updatePackageJsonVersion(cwd, version, logger)

    logger.log(`✅ Version information updated successfully to ${version}`)
  } catch (error) {
    logger.error(
      `❌ Failed to update version information: ${(error as Error).message}`,
    )
    throw error
  }
}
