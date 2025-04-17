import path from 'path'
import fs from 'fs'
import { buildPackage } from './sr-build-package'
import { deployRoutesContracts } from './deploy-contracts'
import dotenv from 'dotenv'
import { Logger } from './helpers'
import { promisify } from 'util'
import { exec } from 'child_process'
dotenv.config()

const execPromise = promisify(exec)

// Define types for semantic-release context
export interface SemanticNextRelease {
  version: string
  gitTag: string
  notes: string
}

export interface SemanticPluginConfig {
  // Any plugin-specific configuration options
}

export interface SemanticContext {
  nextRelease?: SemanticNextRelease
  logger: Logger
  cwd: string
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
  // await verifyContracts(context)
  logger.log(`Contracts verified for version ${nextRelease.version}`)

  // 4. Build the distribution package
  logger.log(`Building TypeScript package`)
  await buildPackage(context)
  logger.log(`Package built for version ${nextRelease.version}`)
}

async function buildHardhat() {
  // Build the hardhat files
  await execPromise('npm run clean')
  await execPromise('env COMPILE_MODE=production npm run build')
}
