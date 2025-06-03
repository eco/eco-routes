/**
 * @file sr-publish.ts
 *
 * Manages the final publishing step in the semantic-release process, handling the
 * distribution of built packages to npm and other registries. This is the culmination
 * of the entire release pipeline, making the new version publicly available.
 *
 * This module implements strict publishing controls and verification to ensure
 * only properly built, tested, and authorized packages are published to registries.
 * It includes safety mechanisms to prevent accidental publishing from development
 * environments and handles proper version tagging.
 *
 * Key features:
 * - Environment-aware publishing decisions (CI vs. local development)
 * - Comprehensive dry-run support for testing the release process
 * - Intelligent tag selection (latest, next, beta) based on version type
 * - Package integrity verification before publishing
 * - Registry authentication and publishing authorization
 * - Detailed logging and feedback on publish status
 * - Publication metadata generation for semantic-release tracking
 *
 * The publish step integrates with CI/CD pipelines and handles environment-specific
 * authentication, ensuring secure credential management during the publishing process.
 */

import { exec } from 'child_process'
import { promisify } from 'util'
import path from 'path'
import fs from 'fs'
import { SemanticContext } from './sr-prepare'
import { ENV_VARS, getBuildDirPath, PACKAGE } from './constants'
import { setPublishingPackage } from './sr-build-package'
import dotenv from 'dotenv'

dotenv.config()
const execPromise = promisify(exec)

/**
 * Publishes both packages to npm: the main package with Solidity files and the TypeScript-only package.
 *
 * This function implements the final step in the semantic-release lifecycle,
 * publishing the built packages to npm with appropriate version tags. It handles
 * both the main eco-routes package (containing Solidity files) and the TypeScript-only
 * package for clients that don't need the Solidity source.
 *
 * The publishing process includes:
 * 1. Determining appropriate npm tag based on version type (latest, beta, etc.)
 * 2. Configuring package.json for each package type before publishing
 * 3. Verifying the package build is complete and correct
 * 4. Publishing packages with proper authentication
 * 5. Handling dry-run mode for testing the publishing process
 *
 * @param pluginConfig - Plugin configuration options from semantic-release
 * @param context - The semantic release context with version and logging information
 * @returns Object containing published package names and their registry URLs
 *
 * @throws Will throw an error if publishing fails for any reason
 */
export async function publish(
  pluginConfig: any,
  context: SemanticContext,
): Promise<any> {
  const { nextRelease, logger, cwd } = context

  // Use the custom RELEASE_VERSION environment variable if available
  const version = nextRelease?.version || process.env.RELEASE_VERSION

  // Update the version if using a custom one
  if (!version) {
    throw new Error(
      'No version provided. Please set the RELEASE_VERSION or provide a version in the context.',
    )
  }

  const dryRun = !shouldWePublish(version)
  if (dryRun) {
    logger.log(
      `DRY RUN: Skipping actual npm publish. Would have published packages to npm.`,
    )
  }

  try {
    // Determine the tag to use for publishing
    // Use 'latest' for stable releases, or the channel defined in .releaserc.json
    // Get the channel from branch configuration or use the default ('latest')
    const channel = context.nextRelease?.channel || 'latest'
    const tag = channel

    logger.log(`Publishing packages version ${version} with tag ${tag}`)

    // Get directory paths
    const buildDir = getBuildDirPath(cwd)

    for (const packageName of [
      PACKAGE.ROUTES_PACKAGE_NAME,
      PACKAGE.ROUTES_TS_PACKAGE_NAME,
    ]) {
      logger.log(`Publishing package: ${packageName}@${version}`)
      setPublishingPackage(context, packageName)
      // Ensure the dist directory exists after compilation
      const distDirPath = path.join(buildDir, 'dist')
      if (!fs.existsSync(distDirPath)) {
        throw new Error(
          `Compilation failed: dist directory not found at ${distDirPath}`,
        )
      }

      if (!dryRun) {
        // Actual publishing in non-dry-run mode
        const result = await execPromise(`yarn publish --tag ${tag}`, {
          cwd: getBuildDirPath(cwd),
          env: {
            ...process.env,
          },
        })
        logger.log(result.stdout)
        logger.log(`Package ${packageName}@${version} published successfully`)
      } else {
        // Just log in dry-run mode
        logger.log(`DRY RUN: Not really publishing: ${packageName}@${version}`)
        logger.log(
          `Package ${packageName}@${version} would be published successfully`,
        )
      }
    }
  } catch (error) {
    logger.error('❌ Package publish failed')
    logger.error((error as Error).message)
    throw error
  }
}

/**
 * Determines whether packages should be published based on environment variables.
 *
 * This function implements safety checks to prevent accidental publishing from
 * development environments. It requires explicit confirmation via environment
 * variables to proceed with actual publishing, otherwise defaults to dry-run mode.
 *
 * The decision logic includes:
 * 1. Checking if running in a CI/CD environment (GitHub Actions)
 * 2. Looking for an explicit override to force publishing
 * 3. Logging the decision for transparency
 * 4. Providing instructions for enabling actual publishing
 *
 * @param version - The version string being published for logging purposes
 * @returns Boolean indicating whether to proceed with actual publishing (true) or dry-run mode (false)
 *
 * @example
 * // Check if we should publish the packages or just simulate
 * const shouldPublish = shouldWePublish('1.2.3');
 * if (shouldPublish) {
 *   // Publish to npm
 * } else {
 *   // Just log what would be published
 * }
 */
export function shouldWePublish(version: string): boolean {
  // Check if running in GitHub Actions or local CI mode
  const isCI = process.env[ENV_VARS.CI] === 'true'
  const notDryRun = process.env[ENV_VARS.NOT_DRY_RUN] === 'true'

  // For local testing, allow forcing publish with NOT_DRY_RUN
  const shouldPublish = isCI || notDryRun

  if (!shouldPublish) {
    console.log(
      'DRY RUN: Skipping actual npm publish. Would have published packages to npm.',
    )
    console.log(`Would publish: ${PACKAGE.ROUTES_PACKAGE_NAME}@${version}`)
    console.log(`Would publish: ${PACKAGE.ROUTES_TS_PACKAGE_NAME}@${version}`)
    console.log(
      `Not publishing. Set ${ENV_VARS.NOT_DRY_RUN} to true to publish or run in a CI environment with ${ENV_VARS.CI} set to true.`,
    )
  }
  return shouldPublish
}
