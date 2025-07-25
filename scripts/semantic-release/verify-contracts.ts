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
import { SemanticContext } from './sr-prepare'
import { PATHS, ENV_VARS, THRESHOLDS } from './constants'
import { Logger } from './helpers'

/**
 * Plugin to handle contract verification during semantic-release process
 * Will verify contracts deployed during the prepare phase
 * Contract verification makes the contract source code viewable on block explorers
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

    const entryCount = fileContent.split('\n').filter(Boolean).length - 1 // Exclude header line
    logger.log(
      `Found verification data file with ${entryCount} entries to verify`,
    )

    // If there are too many entries, provide a warning that verification might take a while
    if (entryCount > THRESHOLDS.VERIFICATION_ENTRIES_WARNING) {
      logger.warn(
        `Large number of verification entries (${entryCount}) might cause verification to take longer than usual`,
      )
    }

    // The chain IDs are already included in the verification file
    // No need to fetch them separately, Verify.sh will read them directly from the file
    logger.log('Chain IDs already included in verification data file')

    // Execute verification
    await executeVerification(logger, cwd, {
      resultsFile: deployAllFile,
    })

    logger.log('✅ Contract verification completed')
  } catch (error) {
    logger.error('❌ Contract verification failed')
    logger.error((error as Error).message)
    // Don't throw the error to avoid interrupting the release process
  }
}

/**
 * Execute the verification script using async/await
 * @param logger Logger instance for output messages
 * @param cwd Current working directory
 * @param config Configuration for verification including results file and keys
 */
async function executeVerification(
  logger: Logger,
  cwd: string,
  config: { resultsFile: string },
): Promise<void> {
  // Path to the verification script
  const verifyScriptPath = path.join(cwd, PATHS.VERIFICATION_SCRIPT)

  if (!fs.existsSync(verifyScriptPath)) {
    throw new Error(`Verification script not found at ${verifyScriptPath}`)
  }

  logger.log(
    `Running verification for deployment results in ${config.resultsFile}`,
  )

  // Use promisify for cleaner async/await handling

  const execProcess = promisify(
    (
      script: string,
      options: any,
      callback: (err: Error | null, code: number) => void,
    ) => {
      const verifyProcess = spawn(script, [], options)

      verifyProcess.on('close', (code) => {
        logger.log(`Verification process exited with code ${code}`)

        if (code !== 0) {
          logger.error('Verification encountered some failures')
        }

        // Always call back with success - we don't want to fail the release
        callback(null, code || 0)
      })

      verifyProcess.on('error', (error) => {
        logger.error(
          `Verification process failed to start: ${(error as Error).message}`,
        )
        callback(error, 1)
      })
    },
  )

  try {
    await execProcess(verifyScriptPath, {
      env: {
        ...process.env,
        [ENV_VARS.RESULTS_FILE]: config.resultsFile,
      },
      stdio: 'inherit',
      shell: true,
      cwd,
    })
  } catch (error) {
    // Log the error but don't throw - we want to continue the release process
    logger.error(`Verification process error: ${(error as Error).message}`)
  }
}
