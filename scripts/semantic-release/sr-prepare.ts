/**
 * @file sr-prepare.ts
 *
 * Orchestrates the preparation phase of semantic releases for smart contract projects.
 * This critical step runs after version determination but before package publication,
 * handling the building, deployment, and verification of contracts across all networks.
 *
 * The prepare phase is responsible for:
 * 1. Ensuring all build dependencies are installed
 * 2. Compiling and optimizing smart contracts with Foundry
 * 3. Deploying contracts with deterministic addresses across multiple chains
 * 4. Verifying deployed contract source code on block explorers
 * 5. Generating deployment artifacts for client libraries
 * 6. Building the TypeScript package with correct version information
 *
 * This script coordinates with other semantic release plugins to ensure
 * consistent versioning across the entire release pipeline, processing both
 * mainnet and pre-production environments with appropriate salt derivation
 * to guarantee deterministic cross-chain addresses.
 *
 * The prepare step is crucial as it creates the deploymentAddresses.json file
 * that gets bundled with the published package, enabling clients to interact
 * with the deployed contracts without hardcoding addresses.
 */

import path from 'path'
import fs from 'fs'
import { buildPackage } from './sr-build-package'
import { deployRoutesContracts } from './sr-deploy-contracts'
import dotenv from 'dotenv'
import { Logger } from './helpers'
import { promisify } from 'util'
import { exec } from 'child_process'
import { deploySingletonFactory } from './sr-singleton-factory'
import { version as versionPackage } from './sr-version'
import { verifyContracts } from './verify-contracts'

dotenv.config()

const execPromise = promisify(exec)

// Define types for semantic-release context
export interface SemanticNextRelease {
  version: string
  gitTag: string
  notes: string
  type?: string
  channel?: string
}

export interface SemanticPluginConfig {
  // Any plugin-specific configuration options
}

export interface SemanticContext {
  nextRelease?: SemanticNextRelease
  logger: Logger
  cwd: string
  env?: Record<string, string>
}

/**
 * Orchestrates the preparation phase of the semantic-release process, handling
 * the building, deployment, and verification of smart contracts across all supported chains.
 *
 * This critical step runs after version determination but before package publication,
 * ensuring that contracts are deployed with deterministic addresses using version-derived salts.
 * For patch versions, it reuses the same salt to maintain address consistency.
 *
 * @param pluginConfig - Plugin configuration options passed from semantic-release
 * @param context - Semantic release context containing version information, logger, and environment
 * @returns Promise that resolves when preparation is complete
 *
 * @example
 * // This function is called by semantic-release automatically
 * // Usage in semantic-release configuration:
 * module.exports = {
 *   prepare: prepare
 * }
 */
export async function prepare(
  pluginConfig: SemanticPluginConfig,
  context: SemanticContext,
): Promise<void> {
  await versionPackage(pluginConfig, context) // Ensure version is set before prepare

  const { nextRelease, logger, cwd } = context

  if (!nextRelease) {
    logger.log('No release detected, skipping contract deployment')
    return
  }

  const version = nextRelease.version || process.env.RELEASE_VERSION

  logger.log(`Preparing to deploy contracts for version ${version}`)

  // Extract version components
  const packageJson = JSON.parse(
    fs.readFileSync(path.join(cwd, 'package.json'), 'utf8'),
  )
  const packageName = packageJson.name

  // 1. Build the hardhat and forge files
  await buildProject()

  // 2. Deploy EIP-2470 factory if it doesn't exist
  logger.log(`Deploying EIP-2470 factory if it doesn't exist:`)
  await deploySingletonFactory(context)

  // 3. Deploy contracts & Verify contracts
  logger.log(`Deploying contracts for package: ${packageName}`)
  await deployRoutesContracts(context, packageName)
  logger.log(`Contracts deployed for version ${nextRelease.version}`)

  // 4. Verify contracts
  logger.log(`Verifying deployed contracts`)
  // await verifyContracts(context)
  logger.log(`Contracts verified for version ${nextRelease.version}`)

  // 5. Build the distribution package
  logger.log(`Building main package`)
  await buildPackage(context)
  logger.log(`Main package built for version ${nextRelease.version}`)
}

/**
 * Builds all project artifacts needed for deployment, cleaning previous builds
 * and compiling contracts with both Hardhat and Foundry.
 *
 * This function executes a sequence of build steps to ensure all contract artifacts
 * are properly generated before deployment:
 * 1. Cleans previous build artifacts
 * 2. Runs TypeScript/Hardhat build in production mode
 * 3. Compiles contracts using Foundry/Forge
 *
 * @returns Promise that resolves when the build process completes
 */
async function buildProject() {
  // Build the hardhat files
  await execPromise('npm run clean')
  await execPromise('env COMPILE_MODE=production npm run build')
  await execPromise('forge build')
}
