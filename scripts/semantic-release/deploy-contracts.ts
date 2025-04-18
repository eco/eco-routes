/**
 * @file deploy-contracts.ts
 *
 * This file is responsible for deploying smart contracts using deterministic
 * deployment (CREATE3) with specific salts derived from the package version.
 *
 * The deterministic deployment approach ensures that contracts with the same version
 * and salt will have the same address across different deployments and networks,
 * which is critical for cross-chain protocols.
 *
 * Key features:
 * - Supports deploying to multiple environments (production and pre-production)
 * - Uses different salts for different environments but in the same deployment process
 * - Generates production and pre-production addresses from semantic version
 * - Stores deployment results for consumption by client libraries
 *
 * The deployment process:
 * 1. Computes salt values based on semantic version
 * 2. Creates a single results file for all deployments
 * 3. Deploys contracts to each environment with appropriate salt, skipping if already deployed
 * 4. Collects and combines results from all deployments
 * 5. Formats and saves deployment data to JSON for use in the package
 */

import { spawn } from 'child_process'
import path from 'path'
import fs from 'fs'
import { parse as parseCSV } from 'csv-parse/sync'
import { determineSalts } from '../utils/extract-salt'
import { getAddress } from 'viem'
import { SemanticContext } from './sr-prepare'
import {
  PATHS,
  ENV_VARS,
  getDeploymentResultsPath,
  getDeployedAddressesJsonPath,
  getBuildDirPath,
} from './constants'
import dotenv from 'dotenv'
import { Logger } from './helpers'
dotenv.config()

interface Contract {
  address: string
  name: string
  chainId: number
  environment?: string
}

// Define the type for CSV parser records
interface DeploymentRecord {
  chainId: string
  address: string
  contractPath: string
  [key: string]: string // Allow additional properties
}

interface DeploymentResult {
  contracts: Contract[]
  success: boolean
}

export async function deployRoutesContracts(
  context: SemanticContext,
  packageName: string,
): Promise<void> {
  const { nextRelease, logger, cwd } = context
  try {
    // Clean up existing build directory if it exists
    const buildDir = getBuildDirPath(cwd);
    if (fs.existsSync(buildDir)) {
      logger.log(`Deleting existing build directory: ${buildDir}`);
      fs.rmSync(buildDir, { recursive: true, force: true });
      logger.log('Build directory deleted successfully');
    }

    // Determine salts based on version
    const { rootSalt, preprodRootSalt } = await determineSalts(
      nextRelease!.version,
      logger,
    )

    // Set up environment for deployment
    await deployToEnv(
      [
        { salt: rootSalt, environment: 'production' },
        { salt: preprodRootSalt, environment: 'preprod' },
      ],
      logger,
      cwd,
    )

    logger.log('✅ Contract deployment completed successfully')
  } catch (error) {
    logger.error('❌ Contract deployment failed')
    logger.error((error as Error).message)
    throw error
  }
}

/**
 * Deploy contracts using existing deployment infrastructure
 */
async function deployToEnv(
  configs: { salt: string; environment: string }[],
  logger: Logger,
  cwd: string,
): Promise<void> {
  // Check for required environment variables
  const requiredEnvVars = [ENV_VARS.PRIVATE_KEY, ENV_VARS.ALCHEMY_API_KEY]
  for (const envVar of requiredEnvVars) {
    if (!process.env[envVar]) {
      throw new Error(`Required environment variable ${envVar} is not set`)
    }
  }

  // Define output directory and ensure it exists
  const outputDir = path.join(cwd, PATHS.OUTPUT_DIR)
  const deployedContractFilePath = getDeployedAddressesJsonPath(cwd)
  const resultsFile = getDeploymentResultsPath(cwd)

  fs.mkdirSync(outputDir, { recursive: true })
  fs.mkdirSync(path.dirname(deployedContractFilePath), { recursive: true })

  // Initialize contracts collection
  let allContracts: Contract[] = []

  // Clean up the results file once at the beginning of all deployments
  // This ensures we have a single file with all deployment results
  if (fs.existsSync(resultsFile)) {
    logger.log(`Cleaning up previous deployment results file: ${resultsFile}`)
    fs.unlinkSync(resultsFile)
  }

  // Create an empty results file
  fs.writeFileSync(resultsFile, '', 'utf-8')
  logger.log(`Created empty deployment results file: ${resultsFile}`)

  // Deploy contracts for each environment
  for (const config of configs) {
    logger.log(`Deploying ${config.environment} contracts...`)

    // Deploy contracts and get results
    const result = await deployContracts(config.salt, logger, cwd, resultsFile)

    if (!result.success) {
      throw new Error(`Deployment failed for ${config.environment} environment`)
    }

    // Add environment info to contracts
    const contractsWithEnv = result.contracts.map((contract) => ({
      ...contract,
      environment: config.environment,
    }))

    allContracts = [...allContracts, ...contractsWithEnv]
  }

  // Save all contracts to JSON
  const contractsJson = processContractsForJson(allContracts)
  fs.writeFileSync(
    deployedContractFilePath,
    JSON.stringify(contractsJson, null, 2),
  )

  logger.log(`Contract addresses saved to ${deployedContractFilePath}`)
}

/**
 * Process contracts array into the required JSON format
 */
function processContractsForJson(
  contracts: Contract[],
): Record<string, Record<string, string>> {
  // Group by chain ID and environment
  const groupedContracts: Record<string, Contract[]> = {}

  for (const contract of contracts) {
    const key = `${contract.chainId}${contract.environment === 'preprod' ? '-pre' : ''}`
    if (!groupedContracts[key]) {
      groupedContracts[key] = []
    }
    groupedContracts[key].push(contract)
  }

  // Convert to desired format
  return Object.fromEntries(
    Object.entries(groupedContracts).map(([key, contracts]) => {
      const names = contracts.map((c) => c.name)
      const addresses = contracts.map((c) => c.address)

      const contractMap: Record<string, string> = {}
      for (let i = 0; i < names.length; i++) {
        contractMap[names[i]] = getAddress(addresses[i])
      }

      return [key, contractMap]
    }),
  )
}

/**
 * Deploy contracts using the MultiDeploy.sh script and return the results
 */
async function deployContracts(
  salt: string,
  logger: Logger,
  cwd: string,
  resultsFile: string,
): Promise<DeploymentResult> {
  return new Promise((resolve, reject) => {
    // Path to the deployment script
    const deployScriptPath = path.join(cwd, PATHS.DEPLOY_SCRIPT)
    const outputDir = path.join(cwd, PATHS.OUTPUT_DIR)

    if (!fs.existsSync(deployScriptPath)) {
      return reject(
        new Error(`Deployment script not found at ${deployScriptPath}`),
      )
    }

    logger.log(`Running deployment with salt: ${salt}`)

    // Create output directory if it doesn't exist
    fs.mkdirSync(outputDir, { recursive: true })

    const deployProcess = spawn(deployScriptPath, [], {
      env: {
        ...process.env,
        [ENV_VARS.SALT]: salt,
        [ENV_VARS.RESULTS_FILE]: resultsFile,
        [ENV_VARS.APPEND_RESULTS]: 'true', // Add a flag to indicate we want to append results
      },
      stdio: 'inherit',
      shell: true,
      cwd,
    })

    deployProcess.on('close', (code) => {
      logger.log(`Deployment process exited with code ${code}`)

      if (code !== 0) {
        return resolve({ contracts: [], success: false })
      }

      // Read deployment results
      if (fs.existsSync(resultsFile)) {
        const contracts = parseDeploymentResults(resultsFile, logger)
        resolve({ contracts, success: true })
      } else {
        logger.error(`Deployment results file not found at ${resultsFile}`)
        resolve({ contracts: [], success: false })
      }
    })
    deployProcess.on('error', (error) => {
      logger.error(`Deployment process failed: ${(error as Error).message}`)
      reject({ contracts: [], success: false })
    })
  })
}

/**
 * Parse all deployment results from the results file using CSV library
 *
 * @param filePath - Path to the CSV file containing deployment results
 * @param logger - Logger instance for output messages
 * @returns Array of Contract objects parsed from the file
 */
function parseDeploymentResults(filePath: string, logger?: Logger): Contract[] {
  if (!fs.existsSync(filePath)) {
    logger?.log(`Deployment results file not found: ${filePath}`)
    return []
  }

  try {
    const fileContent = fs.readFileSync(filePath, 'utf-8')

    // Skip empty file
    if (!fileContent.trim()) {
      logger?.log(`Deployment results file is empty: ${filePath}`)
      return []
    }

    // CSV parse options
    const parseOptions = {
      columns: ['chainId', 'address', 'contractPath'],
      skip_empty_lines: true,
      trim: true,
      relax_column_count: true, // Handle rows with missing fields
      from_line: 1, // Start from the first line
      delimiter: ',', // Specify delimiter explicitly
      // Handle any comment lines in the file
      comment: '#',
      // Specify type casting
      cast: (value: string, context: { column: string }) => {
        if (context.column === 'chainId') {
          const parsedValue = parseInt(value, 10)
          return isNaN(parsedValue) ? value : parsedValue
        }
        return value
      },
    }

    // Parse CSV content
    // @ts-expect-error csv-parse/sync does not have type definitions for the cast option
    const records = parseCSV(fileContent, parseOptions) as DeploymentRecord[]

    // Process each record to extract contract name
    return records
      .filter((record) => {
        const isValid =
          record.chainId &&
          record.address &&
          record.contractPath &&
          record.contractPath.includes(':')

        if (!isValid && logger) {
          logger.log(
            `Skipping invalid deployment record: ${JSON.stringify(record)}`,
          )
        }

        return isValid
      })
      .map((record) => {
        // Extract contract name from the path
        const [, contractName] = record.contractPath.split(':')

        return {
          address: record.address,
          name: contractName,
          // Ensure chainId is a number
          chainId:
            typeof record.chainId === 'number'
              ? record.chainId
              : parseInt(record.chainId, 10),
        }
      })
  } catch (error) {
    // Log error but don't crash the process
    if (logger) {
      logger.error(
        `Error parsing deployment results from ${filePath}: ${(error as Error).message}`,
      )
    } else {
      console.error(
        `Error parsing deployment results: ${(error as Error).message}`,
      )
    }
    return []
  }
}
