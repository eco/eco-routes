import { spawn } from 'child_process'
import path from 'path'
import fs from 'fs'
import { parse as parseCSV } from 'csv-parse/sync'
import { determineSalts, Logger } from '../utils/extract-salt'
import { transformAddresses } from '../deploy/addresses'
import { addressesToCVS } from '../deploy/csv'
import { getAddress } from 'viem'

// Define types for semantic-release context
interface NextRelease {
  version: string
  gitTag: string
  notes: string
}

interface Context {
  nextRelease?: NextRelease
  logger: Logger
  cwd: string
}

interface PluginConfig {
  // Any plugin-specific configuration options
}

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
  [key: string]: string  // Allow additional properties
}

interface DeploymentResult {
  contracts: Contract[]
  success: boolean
}
async function main() {
  // Example usage of the preparePlugin function
  const pluginConfig: PluginConfig = {}
  const context: Context = {
    nextRelease: { version: '1.0.0', gitTag: 'v1.0.0', notes: 'Initial release' },
    logger: {
      log: console.log,
      error: console.error,
      warn: console.warn
    },
    cwd: process.cwd()
  }

  await preparePlugin(pluginConfig, context)
}
main().catch((err) => {
  console.error('Error:', err)
})


/**
 * Plugin to handle contract deployment during semantic-release process
 * Will deploy contracts with deterministic addresses by reusing salt for patch versions
 */
export async function preparePlugin(pluginConfig: PluginConfig, context: Context): Promise<void> {
  const { nextRelease, logger, cwd } = context

  if (!nextRelease) {
    logger.log('No release detected, skipping contract deployment')
    return
  }

  logger.log(`Preparing to deploy contracts for version ${nextRelease.version}`)

  // Extract version components
  const packageJson = JSON.parse(fs.readFileSync(path.join(cwd, 'package.json'), 'utf8'))
  const packageName = packageJson.name

  try {
    // Determine salts based on version
    const { rootSalt, preprodRootSalt } = await determineSalts(
      nextRelease.version,
      packageName,
      logger
    )

    // Set up environment for deployment
    await setupEnvAndDeploy(
      [
        { salt: rootSalt, environment: 'production' },
        { salt: preprodRootSalt, environment: 'preprod' }
      ],
      logger,
      cwd
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
async function setupEnvAndDeploy(
  configs: { salt: string; environment: string }[],
  logger: Logger,
  cwd: string
): Promise<void> {
  // Check for required environment variables
  const requiredEnvVars = ['PRIVATE_KEY', 'CHAIN_IDS']
  for (const envVar of requiredEnvVars) {
    // if (!process.env[envVar]) {
    //   throw new Error(`Required environment variable ${envVar} is not set`)
    // }
  }

  // Define output directory and ensure it exists
  const outputDir = path.join(cwd, 'out')
  const deployedContractFilePath = path.join(cwd, 'build', 'deployAddresses.json')

  fs.mkdirSync(outputDir, { recursive: true })
  fs.mkdirSync(path.dirname(deployedContractFilePath), { recursive: true })

  // Initialize contracts collection
  let allContracts: Contract[] = []

  // Deploy contracts for each environment
  for (const config of configs) {
    logger.log(`Deploying ${config.environment} contracts...`)

    // Deploy contracts and get results
    const result = await deployContracts(config.salt, logger, cwd)

    if (!result.success) {
      throw new Error(`Deployment failed for ${config.environment} environment`)
    }

    // Add environment info to contracts
    const contractsWithEnv = result.contracts.map(contract => ({
      ...contract,
      environment: config.environment
    }))

    allContracts = [...allContracts, ...contractsWithEnv]
  }

  // Save all contracts to JSON
  const contractsJson = processContractsForJson(allContracts)
  fs.writeFileSync(deployedContractFilePath, JSON.stringify(contractsJson, null, 2))

  logger.log(`Contract addresses saved to ${deployedContractFilePath}`)

  // Run address transformations from original script
  try {
    transformAddresses()
    addressesToCVS()
    logger.log('Address transformations completed')
  } catch (error) {
    logger.warn?.(`Address transformation failed: ${(error as Error).message}`)
  }
}

/**
 * Process contracts array into the required JSON format
 */
export function processContractsForJson(contracts: Contract[]): Record<string, Record<string, string>> {
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
      const names = contracts.map(c => c.name)
      const addresses = contracts.map(c => c.address)

      const contractMap: Record<string, string> = {}
      for (let i = 0; i < names.length; i++) {
        contractMap[names[i]] = getAddress(addresses[i])
      }

      return [key, contractMap]
    })
  )
}

/**
 * Deploy contracts using the MultiDeploy.sh script and return the results
 */
export async function deployContracts(
  salt: string,
  logger: Logger,
  cwd: string
): Promise<DeploymentResult> {
  return new Promise((resolve, reject) => {
    // Path to the deployment script
    const deployScriptPath = path.join(cwd, 'scripts', 'MultiDeploy.sh')
    const outputDir = path.join(cwd, 'out')
    const resultsFile = path.join(outputDir, 'deployment-results.txt')

    if (!fs.existsSync(deployScriptPath)) {
      return reject(new Error(`Deployment script not found at ${deployScriptPath}`))
    }

    logger.log(`Running deployment with salt: ${salt}`)

    // Ensure results file doesn't exist from a previous run
    if (fs.existsSync(resultsFile)) {
      fs.unlinkSync(resultsFile)
    }
    
    // Create output directory if it doesn't exist
    fs.mkdirSync(outputDir, { recursive: true })

    const deployProcess = spawn(deployScriptPath, [], {
      env: {
        ...process.env,
        SALT: salt,
        RESULTS_FILE: resultsFile
      },
      stdio: 'inherit',
      shell: true,
      cwd: cwd
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
 * Parse deployment results from the results file using CSV library
 * 
 * @param filePath - Path to the CSV file containing deployment results
 * @param logger - Logger instance for output messages
 * @returns Array of Contract objects parsed from the file
 */
export function parseDeploymentResults(filePath: string, logger?: Logger): Contract[] {
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
      from_line: 1,             // Start from the first line
      delimiter: ',',           // Specify delimiter explicitly
      // Handle any comment lines in the file
      comment: '#',
      // Specify type casting
      cast: (value: string, context: { column: string }) => {
        if (context.column === 'chainId') {
          const parsedValue = parseInt(value, 10)
          return isNaN(parsedValue) ? value : parsedValue
        }
        return value
      }
    }
    
    // Parse CSV content
    const records = parseCSV(fileContent, parseOptions) as DeploymentRecord[]
    
    // Process each record to extract contract name
    return records
      .filter(record => {
        const isValid = record.chainId && record.address && record.contractPath && 
                        record.contractPath.includes(':')
        
        if (!isValid && logger) {
          logger.log(`Skipping invalid deployment record: ${JSON.stringify(record)}`)
        }
        
        return isValid
      })
      .map(record => {
        // Extract contract name from the path
        const [, contractName] = record.contractPath.split(':')
        
        return {
          address: record.address,
          name: contractName,
          // Ensure chainId is a number
          chainId: typeof record.chainId === 'number' 
            ? record.chainId 
            : parseInt(record.chainId, 10)
        }
      })
  } catch (error) {
    // Log error but don't crash the process
    if (logger) {
      logger.error(`Error parsing deployment results from ${filePath}: ${(error as Error).message}`)
    } else {
      console.error(`Error parsing deployment results: ${(error as Error).message}`)
    }
    return []
  }
}