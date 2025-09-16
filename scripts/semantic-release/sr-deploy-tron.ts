/**
 * @file sr-deploy-tron.ts
 *
 * Handles the integration of Tron deployment into the semantic release workflow.
 * This module orchestrates the deployment sequence where Tron contracts are deployed first
 * to obtain the polymer prover address needed for EVM deployments.
 *
 * Key features:
 * - Deploy Portal and Prover contracts to Tron networks
 * - Predict and provide EVM addresses for Polymer Prover on target chains
 * - Coordinate deployment sequence: Tron → EVM with dependency management
 * - Integration with existing semantic release deployment pipeline
 */

import { Logger } from './helpers'
import { executeProcess } from '../utils/processUtils'
import { validateEnvVariables } from '../utils/envUtils'
import { SemanticContext } from './sr-prepare'
import { Hex } from 'viem'
import path from 'path'
import fs from 'fs'
import { parse as parseCSV } from 'csv-parse/sync'
import { getTargetChainIds } from '../utils/fetchChainData'
import { spawn } from 'child_process'
import { TronWeb } from 'tronweb'

interface TronDeploymentResult {
  portal?: string
  polymerProver?: string
  chainId: number
}

interface DeploymentRecord {
  ChainID: string
  ContractAddress: string
  ContractPath: string
  ContractArguments: string
}

/**
 * Converts Tron base58 address to hex format for EVM compatibility
 * @param base58Address - Tron address in base58 format (e.g., TLWEMdEZKbtW4wibbzJdDhzxuc1mKsomfk)
 * @returns Hex address (e.g., 0x1234...abcd)
 */
function convertTronAddressToHex(base58Address: string): string {
  try {
    // Create a minimal TronWeb instance just for address conversion
    const tronWeb = new TronWeb({
      fullHost: 'https://api.shasta.trongrid.io', // Dummy URL, not used for conversion
      privateKey:
        '0x0000000000000000000000000000000000000000000000000000000000000001', // Dummy key
    })

    return tronWeb.address.toHex(base58Address)
  } catch (error) {
    throw new Error(
      `Failed to convert Tron address ${base58Address} to hex: ${(error as Error).message}`,
    )
  }
}

/**
 * Deploys contracts to Tron network first, then to EVM networks with proper dependency management.
 * This function implements the deployment sequence described in @plans/tron.md:
 *
 * 1. Deploy Portal on Tron
 * 2. Predict Polymer Prover addresses on EVM chains (create3, plasma, worldchain)
 * 3. Deploy Polymer Prover on Tron with Portal address and predicted EVM addresses
 * 4. Deploy EVM contracts using the actual Tron Polymer Prover address
 *
 * @param context - The semantic release context containing version info and logger
 * @param rootSalt - Root salt for deterministic deployments
 * @param preprodRootSalt - Pre-production root salt
 * @returns Promise that resolves when all deployments are complete
 */
export async function deployTronAndEVMContracts(
  context: SemanticContext,
  rootSalt: Hex,
  preprodRootSalt: Hex,
): Promise<void> {
  const { logger, cwd } = context

  try {
    logger.log('🔄 Starting Tron + EVM deployment sequence...')

    // Step 1: Predict EVM Polymer Prover addresses FIRST (needed for Tron constructor)
    logger.log('🔮 Step 1: Predicting EVM Polymer Prover addresses...')
    const evmPolymerAddresses = await predictEVMPolymerAddresses(
      rootSalt,
      logger,
      cwd,
    )

    // Step 2: Deploy to Tron with predicted EVM addresses as constructor args
    logger.log('📍 Step 2: Deploying to Tron networks with EVM addresses...')
    const tronResults = await deployToTron(
      logger,
      rootSalt,
      cwd,
      evmPolymerAddresses,
    )

    // Step 3: Verify Tron deployment included EVM addresses
    if (tronResults.polymerProver && evmPolymerAddresses.length > 0) {
      logger.log(
        '🔗 Step 3: Tron Polymer Prover deployed with predicted EVM addresses',
      )
    } else if (tronResults.polymerProver) {
      logger.log(
        '⚠️  Step 3: Tron Polymer Prover deployed without EVM cross-VM provers',
      )
    }

    // Step 4: Deploy to EVM networks with Tron Polymer Prover address
    logger.log('⚡ Step 4: Deploying to EVM networks with Tron dependencies...')
    await deployToEVM(logger, rootSalt, preprodRootSalt, tronResults, cwd)

    logger.log('✅ Tron + EVM deployment sequence completed successfully')
  } catch (error) {
    logger.error('❌ Tron + EVM deployment sequence failed')
    logger.error((error as Error).message)
    throw error
  }
}

/**
 * Deploys contracts to Tron networks using the existing tron-deploy script.
 *
 * @param logger - Logger instance for output messages
 * @param rootSalt - Root salt for deterministic deployments
 * @param cwd - Current working directory
 * @param evmPolymerAddresses - Predicted EVM Polymer Prover addresses for cross-VM provers
 * @returns Promise resolving to Tron deployment results
 */
async function deployToTron(
  logger: Logger,
  rootSalt: Hex,
  cwd: string,
  evmPolymerAddresses: string[] = [],
): Promise<TronDeploymentResult> {
  try {
    // Convert EVM addresses to bytes32 format for Tron constructor
    const crossVmProvers = evmPolymerAddresses
      .map((addr) => {
        // Ensure address is properly formatted (remove 0x prefix, pad to 64 chars)
        const cleanAddr = addr.replace('0x', '').toLowerCase()
        return `0x${cleanAddr.padStart(64, '0')}`
      })
      .join(',')

    // Set up environment for Tron deployment
    const tronEnv = {
      ...process.env,
      SALT: rootSalt,
      DEPLOY_FILE: path.join(cwd, 'out', 'tron-deploy.csv'),
      // Pass predicted EVM addresses as cross-VM provers for Polymer Prover constructor
      POLYMER_CROSS_VM_PROVERS: crossVmProvers,
    }

    if (evmPolymerAddresses.length > 0) {
      logger.log(
        `🌐 Using ${evmPolymerAddresses.length} predicted EVM addresses as cross-VM provers`,
      )
      logger.log(`📋 Cross-VM Provers: ${crossVmProvers}`)
    } else {
      logger.log(
        '⚠️  No EVM addresses available, Tron deployment will proceed without cross-VM provers',
      )
    }

    logger.log('Running Tron deployment script...')

    // Execute the tron deployment script
    const exitCode = await executeProcess(
      'npx',
      ['tsx', 'scripts/tron-deploy.ts'],
      tronEnv,
      cwd,
    )

    if (exitCode !== 0) {
      throw new Error(`Tron deployment failed with exit code ${exitCode}`)
    }

    // Parse results from Tron deployment
    return parseTronDeploymentResults(tronEnv.DEPLOY_FILE, logger)
  } catch (error) {
    logger.error(`Tron deployment failed: ${(error as Error).message}`)
    throw error
  }
}

/**
 * Predicts unique EVM Polymer Prover addresses for chains with crossL2proverV2 configuration.
 * Uses the new PredictAddresses.s.sol script to get accurate predictions from chain data.
 * This must be called before deploying Tron Polymer Prover since these addresses
 * are constructor arguments for the Tron deployment.
 *
 * @param rootSalt - Root salt for deterministic deployments
 * @param logger - Logger instance
 * @param cwd - Current working directory
 * @returns Array of unique predicted EVM addresses as hex strings
 */
async function predictEVMPolymerAddresses(
  rootSalt: Hex,
  logger: Logger,
  cwd: string,
): Promise<string[]> {
  try {
    logger.log('🔮 Predicting EVM Polymer Prover addresses from chain data...')

    const chainDataUrl = process.env.CHAIN_DATA_URL
    if (!chainDataUrl) {
      logger.log('⚠️  CHAIN_DATA_URL not set, skipping EVM address prediction')
      return []
    }

    // Get target chain IDs (only chains with crossL2proverV2 field)
    const chainIds = await getTargetChainIds(chainDataUrl, logger)

    if (chainIds.length === 0) {
      logger.log('⚠️  No chains with crossL2proverV2 found in chain data')
      return []
    }

    const chainIdsStr = chainIds.join(',')
    logger.log(
      `📊 Found ${chainIds.length} chains with crossL2proverV2: ${chainIdsStr}`,
    )

    // Execute forge script to get all unique predictions
    const forgeProcess = spawn(
      'forge',
      [
        'script',
        'scripts/PredictAddresses.s.sol:PredictAddresses',
        '--sig',
        'predictPolymerProverForAllChains()',
      ],
      {
        env: {
          ...process.env,
          SALT: rootSalt,
          PRIVATE_KEY:
            process.env.PRIVATE_KEY ||
            '0x0000000000000000000000000000000000000000000000000000000000000001',
          TARGET_CHAIN_IDS: chainIdsStr,
        },
        cwd,
      },
    )

    let output = ''
    let errorOutput = ''

    forgeProcess.stdout.on('data', (data) => {
      output += data.toString()
    })

    forgeProcess.stderr.on('data', (data) => {
      errorOutput += data.toString()
    })

    await new Promise<void>((resolve, reject) => {
      forgeProcess.on('close', (code) => {
        if (code !== 0) {
          reject(
            new Error(`Forge script failed with code ${code}: ${errorOutput}`),
          )
        } else {
          resolve()
        }
      })
    })

    // Parse output to extract unique addresses
    const addressMatches = output.matchAll(
      /UNIQUE_ADDRESS: (0x[a-fA-F0-9]{40})/g,
    )
    const uniqueAddresses = [...addressMatches].map((m) => m[1])

    logger.log(
      `✅ Found ${uniqueAddresses.length} unique Polymer Prover addresses:`,
    )
    uniqueAddresses.forEach((addr) => logger.log(`  📍 ${addr}`))

    return uniqueAddresses
  } catch (error) {
    logger.error(`❌ Address prediction failed: ${(error as Error).message}`)
    return []
  }
}

/**
 * Gets the comma-separated list of EVM Polymer Prover addresses for use as cross-VM provers.
 *
 * @param rootSalt - Root salt for deterministic deployments
 * @param logger - Logger instance
 * @param cwd - Current working directory
 * @returns Comma-separated string of predicted addresses
 */
async function getEVMPolymerProverAddresses(
  rootSalt: Hex,
  logger: Logger,
  cwd: string,
): Promise<string> {
  const addresses = await predictEVMPolymerAddresses(rootSalt, logger, cwd)
  return addresses.join(',')
}

/**
 * Deploys contracts to EVM networks using the existing deployRoutes.sh script.
 * Uses the Tron Polymer Prover address as a cross-VM prover for EVM deployments.
 *
 * @param logger - Logger instance
 * @param rootSalt - Root salt for deterministic deployments
 * @param preprodRootSalt - Pre-production root salt
 * @param tronResults - Results from Tron deployment containing contract addresses
 * @param cwd - Current working directory
 */
async function deployToEVM(
  logger: Logger,
  rootSalt: Hex,
  preprodRootSalt: Hex,
  tronResults: TronDeploymentResult,
  cwd: string,
): Promise<void> {
  try {
    // Validate environment variables
    validateEnvVariables()

    // Deploy with production salt
    logger.log('Deploying EVM contracts with production salt...')
    await deployEVMWithSalt(logger, rootSalt, tronResults, cwd, 'production')

    // Deploy with pre-production salt
    logger.log('Deploying EVM contracts with pre-production salt...')
    await deployEVMWithSalt(
      logger,
      preprodRootSalt,
      tronResults,
      cwd,
      'pre-production',
    )
  } catch (error) {
    logger.error(`EVM deployment failed: ${(error as Error).message}`)
    throw error
  }
}

/**
 * Deploys EVM contracts with a specific salt environment.
 *
 * @param logger - Logger instance
 * @param salt - Salt for deterministic deployment
 * @param tronResults - Tron deployment results
 * @param cwd - Current working directory
 * @param environment - Environment name for logging
 */
async function deployEVMWithSalt(
  logger: Logger,
  salt: Hex,
  tronResults: TronDeploymentResult,
  cwd: string,
  environment: string,
): Promise<void> {
  const resultsPath = path.join(cwd, 'out', `evm-deploy-${environment}.csv`)

  // Clean up previous results
  if (fs.existsSync(resultsPath)) {
    fs.unlinkSync(resultsPath)
  }
  // Convert Tron Polymer Prover address to EVM hex format
  let tronProverHex = ''
  if (tronResults.polymerProver) {
    try {
      // Convert Tron base58 to hex and remove Tron prefix (41) to get EVM format
      const tronHex = TronWeb.address.toChecksumAddress(
        tronResults.polymerProver,
      )
      // Remove "41" prefix and add "0x" prefix for EVM compatibility
      tronProverHex = '0x' + tronHex.slice(2)
      logger.log(
        `🔄 Converting Tron address: ${tronResults.polymerProver} → ${tronProverHex}`,
      )
    } catch (error) {
      logger.error(
        `❌ Failed to convert Tron address: ${(error as Error).message}`,
      )
    }
  }
  // Set up environment with Tron cross-VM provers
  const evmEnv = {
    ...process.env,
    SALT: salt,
    DEPLOY_FILE: resultsPath,
    RESULTS_FILE: resultsPath, // deployRoutes.sh requires RESULTS_FILE to be set
    // Include Tron Polymer Prover as cross-VM prover if available
    ENABLE_TRON_INTEGRATION: 'true',
    TRON_POLYMER_PROVER: tronProverHex,
  }

  // Execute deployRoutes.sh script
  const exitCode = await executeProcess(
    './scripts/deployRoutes.sh',
    [],
    evmEnv,
    cwd,
  )

  if (exitCode !== 0) {
    throw new Error(
      `EVM deployment (${environment}) failed with exit code ${exitCode}`,
    )
  }

  logger.log(`✅ EVM deployment (${environment}) completed successfully`)
}

/**
 * Parses Tron deployment results from CSV file.
 *
 * @param filePath - Path to the Tron deployment results CSV file
 * @param logger - Logger instance
 * @returns Parsed Tron deployment results
 */
function parseTronDeploymentResults(
  filePath: string,
  logger: Logger,
): TronDeploymentResult {
  if (!fs.existsSync(filePath)) {
    logger.log(`Tron deployment results file not found: ${filePath}`)
    return { chainId: 0 }
  }

  try {
    const fileContent = fs.readFileSync(filePath, 'utf-8')

    if (!fileContent.trim()) {
      logger.log(`Tron deployment results file is empty: ${filePath}`)
      return { chainId: 0 }
    }

    const records = parseCSV(fileContent, {
      columns: true,
      skip_empty_lines: true,
      trim: true,
      delimiter: ',',
    }) as unknown as DeploymentRecord[]

    const result: TronDeploymentResult = { chainId: 0 }

    for (const record of records) {
      if (record.ContractPath.includes('Portal')) {
        result.portal = record.ContractAddress
        result.chainId = parseInt(record.ChainID, 10)
      } else if (record.ContractPath.includes('PolymerProver')) {
        result.polymerProver = record.ContractAddress
        result.chainId = parseInt(record.ChainID, 10)
      }
    }

    logger.log(
      `Parsed Tron deployment results: Portal=${result.portal}, PolymerProver=${result.polymerProver}`,
    )
    return result
  } catch (error) {
    logger.error(
      `Error parsing Tron deployment results: ${(error as Error).message}`,
    )
    return { chainId: 0 }
  }
}
