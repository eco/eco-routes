/**
 * @file verify-contracts.ts
 *
 * Manages the verification of deployed contracts on blockchain explorers across multiple networks.
 * This process occurs after successful deployment but before package publishing, ensuring
 * that all deployed contract source code is publicly accessible and verified on-chain.
 *
 * The verification system is designed to be resilient to individual verification failures,
 * allowing the release process to continue even if some verifications fail. This is important
 * because verification services can be unreliable or have temporary issues.
 *
 * Key features:
 * - Flexible verification key management (env variables or JSON file)
 * - Chain-specific API key handling for various explorers
 * - Processes the consolidated deployment results from multiple environments
 * - Automatically detects and removes CSV headers before processing
 * - Non-blocking error handling for resilient releases
 * - Performance management with warnings for large batch verifications
 * - Detailed logging of verification progress and results
 * - Support for constructor arguments from deployment data
 */

import { spawn } from 'child_process'
import path from 'path'
import fs from 'fs'
import { promisify } from 'util'
import { groupBy } from 'lodash'
import { SemanticContext } from './sr-prepare'
import { PATHS, ENV_VARS, THRESHOLDS } from './constants'
import { Logger } from './helpers'

/**
 * Interface for contract verification data
 */
interface ContractData {
  chainId: string
  address: string
  contractPath: string
  constructorArgs: string
}

/**
 * Interface for chain-grouped contracts
 */
interface ChainContracts {
  [chainId: string]: ContractData[]
}

/**
 * Configuration for parallel verification
 */
interface ParallelVerificationConfig {
  maxConcurrentChains: number
  resultsFile: string
}

/**
 * Plugin to handle contract verification during semantic-release process using parallel processing.
 * Will verify contracts deployed during the prepare phase across multiple chains simultaneously.
 * Contract verification makes the contract source code viewable on block explorers.
 *
 * This implementation groups contracts by chain ID and processes multiple chains in parallel
 * to significantly reduce verification time while respecting API rate limits.
 */
export async function verifyContracts(context: SemanticContext): Promise<void> {
  const { nextRelease, logger, cwd } = context

  if (!nextRelease) {
    logger.log('No release detected, skipping contract verification')
    return
  }

  logger.log(`Preparing to verify contracts for version ${nextRelease.version}`)

  try {
    // Check for single verification key
    if (!process.env[ENV_VARS.VERIFICATION_KEY]) {
      logger.error(
        'No verification key found in VERIFICATION_KEY environment variable, skipping contract verification',
      )
      return
    }

    logger.log('Using single verification key for all chains')

    // Set up environment for verification
    const deployAllFile = path.join(
      cwd,
      PATHS.OUTPUT_DIR,
      PATHS.DEPLOYMENT_ALL_FILE,
    )

    // Check if verification data exists
    if (!fs.existsSync(deployAllFile)) {
      logger.error(
        `Verification data file not found at ${deployAllFile}, skipping verification`,
      )
      return
    }

    // Check if the file has content
    const fileContent = fs.readFileSync(deployAllFile, 'utf-8')
    if (!fileContent.trim()) {
      logger.error(
        `Verification data file is empty at ${deployAllFile}, skipping verification`,
      )
      return
    }

    // Parse CSV data and group by chain
    const contracts = parseCSVData(fileContent, logger)
    const chainGroups = groupBy(contracts, 'chainId')
    const chainCount = Object.keys(chainGroups).length
    const totalContracts = contracts.length

    logger.log(
      `Found ${totalContracts} contracts across ${chainCount} chains to verify`,
    )

    // If there are too many entries, provide a warning that verification might take a while
    if (totalContracts > THRESHOLDS.VERIFICATION_ENTRIES_WARNING) {
      logger.warn(
        `Large number of verification entries (${totalContracts}) might cause verification to take longer than usual`,
      )
    }

    // Log chain distribution
    for (const [chainId, chainContracts] of Object.entries(chainGroups)) {
      logger.log(`Chain ${chainId}: ${chainContracts.length} contracts`)
    }

    // Execute parallel verification
    await executeParallelVerification(
      logger,
      cwd,
      {
        maxConcurrentChains: 5, // Configurable concurrency limit
        resultsFile: deployAllFile,
      },
      chainGroups,
    )

    logger.log('✅ Contract verification completed')
  } catch (error) {
    logger.error('❌ Contract verification failed')
    logger.error((error as Error).message)
    // Don't throw the error to avoid interrupting the release process
  }
}

/**
 * Parse CSV data into contract objects
 * @param fileContent Raw CSV file content
 * @param logger Logger instance
 * @returns Array of contract data objects
 */
function parseCSVData(fileContent: string, logger: Logger): ContractData[] {
  const lines = fileContent.split('\n').filter(Boolean)
  const contracts: ContractData[] = []

  // Skip header line if present
  let startIndex = 0
  if (lines[0] && lines[0].includes('ChainID')) {
    logger.log('CSV header detected, skipping first line')
    startIndex = 1
  }

  for (let i = startIndex; i < lines.length; i++) {
    const line = lines[i].trim()
    if (!line) continue

    const [chainId, address, contractPath, constructorArgs = ''] =
      line.split(',')

    if (chainId && address && contractPath) {
      contracts.push({
        chainId: chainId.trim(),
        address: address.trim(),
        contractPath: contractPath.trim(),
        constructorArgs: constructorArgs.trim(),
      })
    }
  }

  return contracts
}

/**
 * Execute verification for multiple chains in parallel
 * @param logger Logger instance
 * @param cwd Current working directory
 * @param config Parallel verification configuration
 * @param chainGroups Contracts grouped by chain ID
 */
async function executeParallelVerification(
  logger: Logger,
  cwd: string,
  config: ParallelVerificationConfig,
  chainGroups: ChainContracts,
): Promise<void> {
  const chainIds = Object.keys(chainGroups)
  const results: { chainId: string; success: boolean; error?: string }[] = []

  logger.log(
    `Starting parallel verification for ${chainIds.length} chains with max concurrency: ${config.maxConcurrentChains}`,
  )

  // Process chains in batches to control concurrency
  for (let i = 0; i < chainIds.length; i += config.maxConcurrentChains) {
    const batch = chainIds.slice(i, i + config.maxConcurrentChains)

    logger.log(
      `Processing batch ${Math.floor(i / config.maxConcurrentChains) + 1}: chains [${batch.join(', ')}]`,
    )

    // Create promises for this batch
    const batchPromises = batch.map(async (chainId) => {
      try {
        await verifyChainContracts(logger, cwd, chainId, chainGroups[chainId])
        results.push({ chainId, success: true })
        logger.log(`✅ Chain ${chainId} verification completed successfully`)
      } catch (error) {
        const errorMessage = (error as Error).message
        results.push({ chainId, success: false, error: errorMessage })
        logger.error(`❌ Chain ${chainId} verification failed: ${errorMessage}`)
      }
    })

    // Wait for all chains in this batch to complete
    await Promise.allSettled(batchPromises)
  }

  // Log summary
  const successful = results.filter((r) => r.success).length
  const failed = results.filter((r) => !r.success).length

  logger.log(`📊 Parallel Verification Summary:`)
  logger.log(`Total chains: ${chainIds.length}`)
  logger.log(`Successfully verified: ${successful}`)
  logger.log(`Failed to verify: ${failed}`)

  if (failed > 0) {
    logger.warn('Some chain verifications failed:')
    results
      .filter((r) => !r.success)
      .forEach((r) => {
        logger.warn(`  Chain ${r.chainId}: ${r.error}`)
      })
  }
}

/**
 * Verify all contracts for a specific chain
 * @param logger Logger instance
 * @param cwd Current working directory
 * @param chainId Chain ID to verify
 * @param contracts Contracts for this chain
 */
async function verifyChainContracts(
  logger: Logger,
  cwd: string,
  chainId: string,
  contracts: ContractData[],
): Promise<void> {
  logger.log(
    `🔄 Starting verification for chain ${chainId} (${contracts.length} contracts)`,
  )

  // Create temporary CSV file for this chain
  const tempFile = path.join(
    cwd,
    PATHS.OUTPUT_DIR,
    `temp_chain_${chainId}_verification.csv`,
  )

  try {
    // Write CSV data for this chain
    const csvLines = ['ChainID,ContractAddress,ContractPath,ContractArguments']
    for (const contract of contracts) {
      csvLines.push(
        `${contract.chainId},${contract.address},${contract.contractPath},${contract.constructorArgs}`,
      )
    }

    fs.writeFileSync(tempFile, csvLines.join('\n'), 'utf-8')

    // Execute verification script for this chain
    await executeVerificationScript(logger, cwd, tempFile, chainId)
  } finally {
    // Clean up temporary file
    if (fs.existsSync(tempFile)) {
      fs.unlinkSync(tempFile)
    }
  }
}

/**
 * Execute the verification script for a specific chain
 * @param logger Logger instance
 * @param cwd Current working directory
 * @param resultsFile Path to the results file
 * @param chainId Chain ID being processed
 */
async function executeVerificationScript(
  logger: Logger,
  cwd: string,
  resultsFile: string,
  chainId: string,
): Promise<void> {
  const verifyScriptPath = path.join(cwd, PATHS.VERIFICATION_SCRIPT)

  if (!fs.existsSync(verifyScriptPath)) {
    throw new Error(`Verification script not found at ${verifyScriptPath}`)
  }

  // Use promisify for cleaner async/await handling
  const execProcess = promisify(
    (
      script: string,
      options: any,
      callback: (err: Error | null, code: number) => void,
    ) => {
      const verifyProcess = spawn(script, [], options)
      let errorOutput = ''

      // Capture stdout and stderr for this specific chain
      if (verifyProcess.stdout) {
        verifyProcess.stdout.on('data', (data) => {
          const text = data.toString()
          // Log with chain prefix for identification
          logger.log(`[Chain ${chainId}] ${text.trim()}`)
        })
      }

      if (verifyProcess.stderr) {
        verifyProcess.stderr.on('data', (data) => {
          const text = data.toString()
          errorOutput += text
          logger.error(`[Chain ${chainId}] ${text.trim()}`)
        })
      }

      verifyProcess.on('close', (code) => {
        if (code !== 0) {
          logger.error(
            `[Chain ${chainId}] Verification process exited with code ${code}`,
          )
          if (errorOutput) {
            callback(
              new Error(`Verification failed: ${errorOutput}`),
              code || 1,
            )
          } else {
            callback(
              new Error(`Verification failed with exit code ${code}`),
              code || 1,
            )
          }
        } else {
          logger.log(
            `[Chain ${chainId}] Verification process completed successfully`,
          )
          callback(null, 0)
        }
      })

      verifyProcess.on('error', (error) => {
        logger.error(
          `[Chain ${chainId}] Verification process failed to start: ${error.message}`,
        )
        callback(error, 1)
      })
    },
  )

  await execProcess(verifyScriptPath, {
    env: {
      ...process.env,
      [ENV_VARS.RESULTS_FILE]: resultsFile,
    },
    stdio: ['pipe', 'pipe', 'pipe'], // Use pipes to capture output
    shell: true,
    cwd,
  })
}
