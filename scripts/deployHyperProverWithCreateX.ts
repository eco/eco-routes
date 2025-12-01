/**
 * @file deployHyperProverWithCreateX.ts
 *
 * Deploys HyperProver contracts across multiple chains using CREATE3 for deterministic
 * deployment. Uses viem for type-safe Ethereum interactions.
 *
 * Key features:
 * - Deterministic deployment: same salt produces same addresses across all chains
 * - Self-reference handling: computes HyperProver address before deployment using CREATE3
 * - Idempotent: skips chains where HyperProver is already deployed
 * - Type-safe: uses viem and TypeScript for all blockchain interactions
 *
 * Note: Uses CREATE3 (not CREATE2) because the address must be computed before deployment
 * to include in the constructor arguments (circular dependency). CREATE3 addresses only
 * depend on the deployer and salt, not the bytecode.
 *
 * CREATE3 Deployer: 0xC6BAd1EbAF366288dA6FB5689119eDd695a66814 (deployed via CREATE2)
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  Hex,
  encodePacked,
  keccak256,
  encodeAbiParameters,
  parseAbiParameters,
  getCreate2Address,
  Address,
  pad,
  encodeFunctionData,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import * as fs from 'fs'
import * as path from 'path'
import * as dotenv from 'dotenv'

dotenv.config()

// ============================================================================
// CONFIGURATION
// ============================================================================

// Chains to deploy to (set to null or empty array to deploy to all chains in config file)
const CHAINS_TO_DEPLOY: string[] | null = ['84532', '11155420', '11155111', '421614']

// CREATE3 deployer address (same on all chains, deployed via CREATE2)
const CREATE3_DEPLOYER_ADDRESS = '0xC6BAd1EbAF366288dA6FB5689119eDd695a66814' as const

// CREATE3 deployer ABI (from ICreate3Deployer.sol)
const CREATE3_DEPLOYER_ABI = [
  {
    inputs: [
      { name: 'initCode', type: 'bytes' },
      { name: 'salt', type: 'bytes32' },
    ],
    name: 'deploy',
    outputs: [{ name: 'deployed', type: 'address' }],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      { name: 'initCode', type: 'bytes' },
      { name: 'deployer', type: 'address' },
      { name: 'salt', type: 'bytes32' },
    ],
    name: 'deployedAddress',
    outputs: [{ name: 'deployed', type: 'address' }],
    stateMutability: 'view',
    type: 'function',
  },
] as const

interface ChainConfig {
  mailbox: Address
  url: string
}

interface DeploymentResult {
  chainId: string
  contractName: string
  contractAddress: Address
  mailbox: Address
  portal: Address
  constructorArgs: string
  success: boolean
  error?: string
}

/**
 * Load chain configuration from JSON file
 */
function loadChainConfig(configPath: string): Record<string, ChainConfig> {
  if (!fs.existsSync(configPath)) {
    throw new Error(`Chain config file not found: ${configPath}`)
  }

  const configData = fs.readFileSync(configPath, 'utf-8')
  return JSON.parse(configData)
}

/**
 * Replace environment variables in RPC URLs
 * Supports both ${VAR_NAME} syntax and plain VAR_NAME
 */
function replaceEnvVars(str: string): string {
  let result = str

  // Replace ${VAR_NAME} syntax
  result = result.replace(/\$\{(\w+)\}/g, (_, varName) => {
    return process.env[varName] || ''
  })

  // Replace common API key placeholders
  if (result.includes('ALCHEMY_API_KEY') && process.env.ALCHEMY_API_KEY) {
    result = result.replace(/ALCHEMY_API_KEY/g, process.env.ALCHEMY_API_KEY)
  }
  if (result.includes('INFURA_API_KEY') && process.env.INFURA_API_KEY) {
    result = result.replace(/INFURA_API_KEY/g, process.env.INFURA_API_KEY)
  }

  return result
}

/**
 * Get HyperProver bytecode from compiled artifacts
 */
function getHyperProverBytecode(): Hex {
  const contractPath = path.join(process.cwd(), 'out', 'HyperProver.sol', 'HyperProver.json')

  if (!fs.existsSync(contractPath)) {
    throw new Error(`HyperProver artifact not found at ${contractPath}. Run 'forge build' first.`)
  }

  const artifact = JSON.parse(fs.readFileSync(contractPath, 'utf-8'))
  return artifact.bytecode.object as Hex
}

/**
 * Compute CREATE3 address for HyperProver with self-reference
 * This solves the circular dependency: HyperProver needs its own address in constructor
 * With CREATE3, the address only depends on deployer and salt, not the bytecode
 */
async function computeHyperProverAddress(
  salt: Hex,
  mailbox: Address,
  portal: Address,
  bytecode: Hex,
  deployer: Address,
  rpcUrl: string,
): Promise<{ address: Address; initCode: Hex }> {
  // Step 1: Query createX to get the CREATE3 address
  const publicClient = createPublicClient({
    transport: http(rpcUrl),
  })

  const predictedAddress = await publicClient.readContract({
    address: CREATE3_DEPLOYER_ADDRESS,
    abi: CREATE3_DEPLOYER_ABI,
    functionName: 'deployedAddress',
    args: ['0x', deployer, salt], // Empty bytecode for address prediction
  }) as Address

  // Step 2: Build initCode with the predicted address as self-reference
  const selfRef = pad(predictedAddress, { size: 32 })

  const constructorArgs = encodeAbiParameters(
    parseAbiParameters('address, address, bytes32[]'),
    [mailbox, portal, [selfRef]]
  )

  const initCode = (bytecode + constructorArgs.slice(2)) as Hex

  return {
    address: predictedAddress,
    initCode,
  }
}

/**
 * Check if contract is already deployed
 */
async function isDeployed(address: Address, rpcUrl: string): Promise<boolean> {
  const client = createPublicClient({
    transport: http(rpcUrl),
  })

  const code = await client.getBytecode({ address })
  return code !== undefined && code !== '0x'
}

/**
 * Deploy HyperProver to a single chain
 */
async function deployToChain(
  chainId: string,
  config: ChainConfig,
  salt: Hex,
  portal: Address,
  privateKey: Hex,
  bytecode: Hex,
): Promise<DeploymentResult> {
  const rpcUrl = replaceEnvVars(config.url)

  console.log(`\n🔄 Processing Chain ID: ${chainId}`)
  console.log(`   Mailbox: ${config.mailbox}`)
  console.log(`   RPC URL: ${rpcUrl}`)

  try {
    // Create clients
    const publicClient = createPublicClient({
      transport: http(rpcUrl),
    })

    const account = privateKeyToAccount(privateKey)
    const walletClient = createWalletClient({
      account,
      transport: http(rpcUrl),
    })

    // Check if CREATE3 deployer is deployed
    const create3Code = await publicClient.getBytecode({
      address: CREATE3_DEPLOYER_ADDRESS
    })

    if (!create3Code || create3Code === '0x') {
      throw new Error(`CREATE3 deployer not deployed at ${CREATE3_DEPLOYER_ADDRESS}`)
    }

    // Compute HyperProver address with self-reference
    const { address: predictedAddress, initCode } = await computeHyperProverAddress(
      salt,
      config.mailbox,
      portal,
      bytecode,
      account.address,
      rpcUrl,
    )

    console.log(`   🔍 Predicted Address: ${predictedAddress}`)

    // Check if already deployed
    const alreadyDeployed = await isDeployed(predictedAddress, rpcUrl)

    if (alreadyDeployed) {
      console.log(`   ✅ HyperProver already deployed at ${predictedAddress}`)

      return {
        chainId,
        contractName: 'HyperProver',
        contractAddress: predictedAddress,
        mailbox: config.mailbox,
        portal,
        constructorArgs: initCode.slice(bytecode.length) as Hex,
        success: true,
      }
    }

    // Deploy using CREATE3 deployer
    console.log(`   🚀 Deploying HyperProver...`)

    const data = encodeFunctionData({
      abi: CREATE3_DEPLOYER_ABI,
      functionName: 'deploy',
      args: [initCode, salt],
    })

    // @ts-expect-error - viem type inference issue with sendTransaction
    const hash = await walletClient.sendTransaction({
      account,
      to: CREATE3_DEPLOYER_ADDRESS,
      data,
    })

    console.log(`   📝 Transaction hash: ${hash}`)

    // Wait for transaction receipt
    const receipt = await publicClient.waitForTransactionReceipt({ hash })

    if (receipt.status === 'success') {
      // Verify deployment (with retry for slow chains)
      let deployed = await isDeployed(predictedAddress, rpcUrl)

      if (!deployed) {
        console.log(`   ⏳ Waiting for deployment to finalize...`)
        await new Promise(resolve => setTimeout(resolve, 5000)) // Wait 5 seconds
        deployed = await isDeployed(predictedAddress, rpcUrl)
      }

      if (!deployed) {
        throw new Error('Deployment transaction succeeded but no code at predicted address')
      }

      console.log(`   ✅ HyperProver deployed successfully at ${predictedAddress}`)

      return {
        chainId,
        contractName: 'HyperProver',
        contractAddress: predictedAddress,
        mailbox: config.mailbox,
        portal,
        constructorArgs: initCode.slice(bytecode.length) as Hex,
        success: true,
      }
    } else {
      throw new Error(`Transaction reverted: ${hash}`)
    }

  } catch (error) {
    console.error(`   ❌ Error: ${(error as Error).message}`)

    return {
      chainId,
      contractName: 'HyperProver',
      contractAddress: '0x0000000000000000000000000000000000000000',
      mailbox: config.mailbox,
      portal,
      constructorArgs: '0x',
      success: false,
      error: (error as Error).message,
    }
  }
}

/**
 * Save deployment results to CSV
 */
function saveResults(results: DeploymentResult[], outputPath: string): void {
  const dir = path.dirname(outputPath)
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true })
  }

  const csvHeader = 'ChainID,ContractName,ContractAddress,Mailbox,Portal,ConstructorArgs,Success,Error\n'
  const csvRows = results.map(r =>
    `${r.chainId},${r.contractName},${r.contractAddress},${r.mailbox},${r.portal},${r.constructorArgs},${r.success},${r.error || ''}`
  ).join('\n')

  // Add trailing newline so shell scripts can read all lines
  fs.writeFileSync(outputPath, csvHeader + csvRows + '\n')
  console.log(`\n📊 Results saved to: ${outputPath}`)
}

/**
 * Main deployment function
 */
async function main() {
  console.log('🚀 HyperProver CreateX Deployment')
  console.log('==================================\n')

  // Load environment variables
  const configFile = process.env.CHAIN_CONFIG_FILE
  const portalAddress = process.env.PORTAL_ADDRESS as Address
  const salt = process.env.SALT as Hex
  const privateKey = process.env.PRIVATE_KEY as Hex

  // Validate required environment variables
  if (!configFile) {
    throw new Error('CHAIN_CONFIG_FILE not set')
  }
  if (!portalAddress) {
    throw new Error('PORTAL_ADDRESS not set')
  }
  if (!salt) {
    throw new Error('SALT not set')
  }
  if (!privateKey) {
    throw new Error('PRIVATE_KEY not set')
  }

  console.log(`Portal Address: ${portalAddress}`)
  console.log(`Salt: ${salt}`)
  console.log(`Config File: ${configFile}`)

  // Load chain configuration
  const chainConfigs = loadChainConfig(configFile)
  let chainIds = Object.keys(chainConfigs)

  // Filter chains if CHAINS_TO_DEPLOY is set
  if (CHAINS_TO_DEPLOY && CHAINS_TO_DEPLOY.length > 0) {
    console.log(`\n🎯 Filtering to specific chains: ${CHAINS_TO_DEPLOY.join(', ')}`)

    chainIds = chainIds.filter(chainId => CHAINS_TO_DEPLOY.includes(chainId))

    // Warn about chains that were specified but not found in config
    const missingChains = CHAINS_TO_DEPLOY.filter(c => !Object.keys(chainConfigs).includes(c))
    if (missingChains.length > 0) {
      console.log(`⚠️  Warning: Chains not found in config: ${missingChains.join(', ')}`)
    }

    if (chainIds.length === 0) {
      throw new Error('No valid chains to deploy to. Check CHAINS_TO_DEPLOY array.')
    }
  }

  console.log(`\nDeploying to ${chainIds.length} chain(s)`)

  // Get HyperProver bytecode
  const bytecode = getHyperProverBytecode()
  console.log(`HyperProver bytecode loaded (${bytecode.length} bytes)`)

  // Deploy to all chains
  const results: DeploymentResult[] = []

  for (const chainId of chainIds) {
    const config = chainConfigs[chainId]
    const result = await deployToChain(
      chainId,
      config,
      salt,
      portalAddress,
      privateKey,
      bytecode,
    )
    results.push(result)
  }

  // Save results
  const outputPath = path.join(process.cwd(), 'out', 'hyperprover_deployments.csv')
  saveResults(results, outputPath)

  // Summary
  const successful = results.filter(r => r.success).length
  const failed = results.filter(r => !r.success).length

  console.log('\n✅ Deployment complete!')
  console.log(`   Successful: ${successful}`)
  console.log(`   Failed: ${failed}`)

  if (failed > 0) {
    console.log('\n❌ Some deployments failed. Check the logs above for details.')
    process.exit(1)
  }
}

// Run main function
main().catch((error) => {
  console.error('Fatal error:', error)
  process.exit(1)
})
