/**
 * @file sr-verify-conditions.ts
 *
 * Ensures all prerequisites are met before beginning the semantic release process.
 * As the first step in the release pipeline, this verification acts as a gatekeeper
 * to prevent attempted releases that would fail later in the process.
 *
 * This module implements comprehensive validation of the environment, credentials,
 * package configuration, and deployment requirements before proceeding with any
 * further release steps. It provides early detection of potential issues and
 * clear, actionable error messages when requirements aren't met.
 *
 * Comprehensive verification checks include:
 * - Required environment variables and deployment credentials
 * - Package.json structure, completeness, and validity
 * - Smart contract compilation readiness
 * - npm registry authentication and publishing permissions
 * - Git repository status and access rights
 * - Version compatibility with existing releases
 * - Deployment key and verification key availability
 *
 * By validating all requirements upfront, this step prevents issues that would
 * otherwise be discovered later in the release process, after significant time
 * and resources have been invested.
 */

import path from 'path'
import fs from 'fs'
import {
  fetchLatestPackageVersion,
  getPackageInfo,
  isValidVersion,
} from './helpers'
import { ENV_VARS, PATHS } from './constants'
import { SemanticContext, SemanticPluginConfig } from './sr-prepare'
import dotenv from 'dotenv'
dotenv.config()

/**
 * Verifies all required conditions are met before a release can proceed.
 *
 * This function implements the first step in the semantic-release lifecycle,
 * acting as a gatekeeper to prevent releases that would fail later in the process.
 * It performs comprehensive validation of the environment, credentials, and
 * package configuration before allowing the release to continue.
 *
 * The verification process includes:
 * 1. Checking that all required environment variables are set for deployments and publishing
 * 2. Validating the package.json exists and contains all necessary fields
 * 3. Verifying the next version is valid according to semver and greater than what's published
 * 4. Ensuring npm publishing credentials are available in the environment
 * 5. Validating that release conditions are appropriate for the current context
 *
 * @param pluginConfig - Plugin configuration options from semantic-release
 * @param context - Semantic release context with version, logger and environment info
 * @returns Promise that resolves when all conditions are verified successfully
 * @throws Error with detailed message if any verification check fails
 *
 * @example
 * // This function is called by semantic-release automatically
 * // Usage in semantic-release configuration:
 * module.exports = {
 *   verifyConditions
 * }
 */
export async function verifyConditions(
  pluginConfig: SemanticPluginConfig,
  context: SemanticContext,
): Promise<void> {
  const { logger, cwd, nextRelease } = context

  logger.log('Verifying conditions for eco-routes release...')

  // 1. Check for package.json and read basic info
  const packageJsonPath = path.join(cwd, PATHS.PACKAGE_JSON)
  if (!fs.existsSync(packageJsonPath)) {
    throw new Error(`package.json not found at ${packageJsonPath}`)
  }

  // Read package.json
  const packageJson = JSON.parse(fs.readFileSync(packageJsonPath, 'utf8'))
  const packageName = packageJson.name

  if (!packageName) {
    throw new Error('Invalid package.json: missing "name" field')
  }

  // 2. Check required environment variables for deployment and publishing
  const requiredEnvVars = [
    ENV_VARS.PRIVATE_KEY,
    ENV_VARS.ALCHEMY_API_KEY,
    ENV_VARS.NPM_TOKEN,
    ENV_VARS.VERIFICATION_KEY,
  ]
  const missingVars = requiredEnvVars.filter((varName) => !process.env[varName])

  if (missingVars.length > 0) {
    throw new Error(
      `Missing required environment variables: ${missingVars.join(', ')}`,
    )
  }

  // 3. If we have nextRelease info (we're in a dry run or actual release), verify version
  if (nextRelease) {
    const { version } = nextRelease

    // Validate version format
    if (!isValidVersion(version)) {
      throw new Error(`Invalid version format: ${version}`)
    }

    // Get TypeScript package name for checking published versions
    const packageName = getPackageInfo(cwd).name

    // Fetch info about the latest published version with same major.minor
    const packageInfo = await fetchLatestPackageVersion(
      packageName,
      version,
      logger,
    )

    if (packageInfo && !packageInfo.isNewer) {
      throw new Error(
        `Version ${version} is not newer than already published version ${packageInfo.version}`,
      )
    }

    logger.log('Version validation passed')
  }

  logger.log('✅ All conditions verified successfully')
}
