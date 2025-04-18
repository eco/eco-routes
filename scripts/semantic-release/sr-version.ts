/**
 * @file sr-version.ts
 *
 * Implements the version step in the semantic-release lifecycle.
 * This step is responsible for updating version information in
 * various files like Solidity contracts and package.json before
 * the prepare step runs.
 *
 * Version updates include:
 * 1. Updating the semver version in package.json
 * 2. Finding and updating all Solidity contract files that implement version() functions
 * 3. Including the git hash in the version string for Solidity contracts
 *
 * The version step is critical for ensuring that deployed contracts report
 * the correct version information and maintaining consistency between
 * on-chain and off-chain components.
 */

import { SemanticContext, SemanticPluginConfig } from './sr-prepare'
import {
  updateSolidityVersions,
  updatePackageJsonVersion,
} from './solidity-version-updater'
import dotenv from 'dotenv'
dotenv.config()

/**
 * Updates version information in all relevant files
 *
 * This is the "version" step in the semantic-release lifecycle
 * It runs after analyzeCommits and before prepare
 *
 * @param pluginConfig - Plugin configuration options
 * @param context - Semantic release context
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

  const version = nextRelease.version
  logger.log(`Updating version information to ${version}`)

  try {
    // 1. Update version in Solidity files
    const updatedFiles = updateSolidityVersions(cwd, version, logger)
    logger.log(`Updated version in ${updatedFiles} Solidity files`)

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
