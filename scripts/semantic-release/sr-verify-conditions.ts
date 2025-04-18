/**
 * @file sr-verify-conditions.ts
 *
 * Implements the verifyConditions step in the semantic-release lifecycle.
 * This is the first step that runs in the process and ensures all prerequisites
 * are met before attempting a release.
 * 
 * The verification process includes:
 * - Checking environment variables for deployment credentials
 * - Validating package.json and its fields
 * - Ensuring the new version is valid and greater than existing versions
 * - Verifying npm publishing credentials
 * 
 * If any verification fails, the release process is aborted with a clear error message.
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
 * Verifies conditions before a release can proceed
 * This is the first step in the semantic-release lifecycle
 *
 * This function:
 * 1. Checks that required environment variables are set for deployments
 * 2. Validates the package.json exists and has required fields
 * 3. Verifies the next version is valid and greater than what's published
 * 4. Ensures publishing credentials are available in the environment
 *
 * @param pluginConfig - Plugin configuration options
 * @param context - Semantic release context with version and logging info
 * @throws Error if any verification check fails
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
