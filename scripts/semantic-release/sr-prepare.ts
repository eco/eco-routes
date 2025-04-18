/**
 * @file sr-prepare.ts
 *
 * Implements the prepare step in the semantic-release lifecycle.
 * This step runs after the version has been determined and version files updated,
 * but before the actual publishing to npm.
 *
 * Responsibilities:
 * 1. Building the Hardhat project
 * 2. Deploying contracts to all configured networks
 * 3. Verifying deployed contracts on block explorers
 * 4. Building the TypeScript package for distribution
 *
 * The prepare step is crucial for ensuring that what gets published
 * contains all the necessary artifacts and deployed contract addresses.
 */

import path from 'path'
import fs from 'fs'
import { buildPackage } from './sr-build-package'
import { deployRoutesContracts } from './deploy-contracts'
import dotenv from 'dotenv'
import { Logger } from './helpers'
import { promisify } from 'util'
import { exec } from 'child_process'
import { verifyContracts } from './verify-contracts'
dotenv.config()

const execPromise = promisify(exec)

// Define types for semantic-release context
export interface SemanticNextRelease {
  version: string
  gitTag: string
  notes: string
  type?: string
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
 * Plugin to handle contract deployment during semantic-release process
 * This is the prepare step in the semantic-release lifecycle
 * Will deploy contracts with deterministic addresses by reusing salt for patch versions
 *
 * @param pluginConfig - Plugin configuration options
 * @param context - Semantic release context
 */
export async function prepare(
  pluginConfig: SemanticPluginConfig,
  context: SemanticContext,
): Promise<void> {
  const { nextRelease, logger, cwd } = context

  if (!nextRelease) {
    logger.log('No release detected, skipping contract deployment')
    return
  }

  logger.log(`Preparing to deploy contracts for version ${nextRelease.version}`)

  // Extract version components
  const packageJson = JSON.parse(
    fs.readFileSync(path.join(cwd, 'package.json'), 'utf8'),
  )
  const packageName = packageJson.name

  // 1. Build the hardhat files
  buildHardhat()

  // 2. Deploy contracts
  logger.log(`Deploying contracts for package: ${packageName}`)
  await deployRoutesContracts(context, packageName)
  logger.log(`Contracts deployed for version ${nextRelease.version}`)

  // 3. Verify contracts
  logger.log(`Verifying deployed contracts`)
  await verifyContracts(context)
  logger.log(`Contracts verified for version ${nextRelease.version}`)

  // 4. Build the distribution package
  logger.log(`Building main package`)
  await buildPackage(context)
  logger.log(`Main package built for version ${nextRelease.version}`)
}

async function buildHardhat() {
  // Build the hardhat files
  await execPromise('npm run clean')
  await execPromise('env COMPILE_MODE=production npm run build')
}
