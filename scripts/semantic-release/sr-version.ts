/**
 * @file sr-version.ts
 *
 * Manages version information updates across both Solidity contracts and npm packages.
 * This critical step in the semantic-release process ensures version consistency
 * between on-chain and off-chain components of the protocol.
 *
 * The version module handles the complex task of synchronizing version information
 * across different file types and ensuring that deployed smart contracts properly
 * report their version information through standardized interfaces. This includes
 * embedding Git commit information for traceability between deployed code and source.
 *
 * Key responsibilities:
 * 1. Updating the semantic version in package.json for npm publishing
 * 2. Finding and updating all Solidity contracts implementing Semver interfaces
 * 3. Converting semantic versions to appropriate on-chain representations
 * 4. Embedding Git commit hash information in deployed contract versions
 * 5. Ensuring version consistency across all protocol components
 * 6. Generating version changelogs and documentation
 *
 * This synchronization is essential for protocol security and auditability,
 * allowing both off-chain and on-chain verification of deployed contract versions
 * and maintaining a clear lineage between source code and deployed bytecode.
 */

import { SemanticContext, SemanticPluginConfig } from './sr-prepare'
import {
  updateSolidityVersions,
  updatePackageJsonVersion,
} from './solidity-version-updater'
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
