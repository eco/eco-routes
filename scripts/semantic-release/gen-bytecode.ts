/**
 * @file gen-bytecode.ts
 *
 * Handles generation of deployment bytecode and initialization data for deterministic
 * contract deployment across chains. This utility prepares the exact bytecode that
 * will be deployed using CREATE2/CREATE3 deployers with specific salts.
 *
 * The module handles:
 * - Generation of correctly formatted initialization bytecode
 * - Computation of constructor argument encoding
 * - Preparation of deployment data for verification tools
 * - Environment-specific salt processing for deterministic addresses
 * - Creation of bytecode artifacts for multi-chain deployment
 *
 * This process is critical for ensuring that contracts deploy to the same addresses
 * across all chains when using the same salt, a key requirement for cross-chain
 * protocols that need consistent addressing.
 */
import {
  encodeFunctionData,
  Hex,
  encodeDeployData,
  keccak256,
  encodeAbiParameters,
} from 'viem'
import fs from 'fs'
import path from 'path'
import { PATHS } from './constants'

// CREATEX Deployer ABI for the deploy function
const CREATE_X_ABI = [
  {
    inputs: [
      { name: 'salt', type: 'bytes32' },
      { name: 'initCode', type: 'bytes' },
    ],
    name: 'deployCreate2',
    outputs: [{ name: 'newContract', type: 'address' }],
    stateMutability: 'payable',
    type: 'function',
  },
]

type Contract = {
  name: 'Portal' | 'HyperProver'
  path: string
  args: any[]
}

// List of contracts to deploy
const CONTRACTS_TO_DEPLOY: Contract[] = [
  {
    name: 'Portal',
    args: [],
    path: 'contracts/Portal.sol:Portal',
  },
  // { name: 'HyperProver', args: [], path: 'contracts/prover/HyperProver.sol:HyperProver' },
]

/**
 * Generates deployment data for all contracts and saves to JSON
 * @param salt The salt to use for all deployments
 * @param chainId The chain ID for the deployments
 * @param outputPath The path to save the JSON file to
 */
export async function generateDeploymentFile(
  salts: { value: Hex; name: string }[],
  outputPath: string,
): Promise<void> {
  console.log(`Generating deployment data with salts ${salts.length}`)
  const deploymentData: Record<string, any> = {}

  // Fetch chain IDs from the deployment data URL
  // If this fails, it will throw an error that should propagate up
  const deployData = await fetchDeployData()

  // Generate bytecode deployment data for each salt
  for (const salt of salts) {
    console.log(
      `Generating deployment data for salt ${JSON.stringify(salt)}...`,
    )
    const data = generateMultipleDeploymentData(salt.value, deployData)
    deploymentData[salt.name] = data
  }

  // Save deployment data
  saveDeploymentData(deploymentData, outputPath)

  console.log('Deployment data generation complete')
}

/**
 * Generates deployment data for multiple contracts using the same salt
 * @param salt The salt to use for all deployments (32 bytes hex string with 0x prefix)
 * @returns Object with deployment data for all contracts
 */
export function generateMultipleDeploymentData(
  salt: Hex,
  chainIDs: string[],
): any {
  // Initialize the deployment data structure with per-chain objects
  const deploymentData: any = {
    salt,
    keccakSalt: keccak256(salt),
    contracts: {},
  }

  // Deploy all contracts in order
  // Making sure that dependencies are available when needed
  const deployedContracts: Record<string, any> = {}

  for (const contract of CONTRACTS_TO_DEPLOY) {
    const contractName = contract.name
    try {
      // Generate the deployment bytecode with the updated args
      const contractData = generateBytecodeDeployData({
        value: 0n,
        salt,
        contract,
      })

      // Store the generated data
      deployedContracts[contractName] = {
        args: contract.args,
        initCodeHash: contractData.initCodeHash,
        encodedArgs: contractData.encodedArgs,
        contractPath: contract.path,
        deployBytecode: contractData.deployBytecode,
      }

      console.log(`Successfully generated ${contractName} deployment data `)
    } catch (error) {
      console.error(`Error generating ${contractName} deployment data:`, error)
    }
  }

  // Store all contracts for this chain
  deploymentData.contracts = deployedContracts

  return deploymentData
}

/**
 * Generates the bytecode and deployment data for a contract
 * @param contractName The name of the contract to deploy (matches the JSON file name)
 * @param salt The salt to use for the CREATE2 deployment (32 bytes hex string with 0x prefix)
 * @param chainId The chain ID to deploy to
 * @returns Object with contract deployment data
 */
export function generateBytecodeDeployData(create2Params: {
  value: bigint
  salt: Hex
  contract: Contract
}): {
  contractName: string
  salt: Hex
  initCodeHash: Hex
  args: any[]
  encodedArgs: string
  deployBytecode: Hex
} {
  const { salt, contract } = create2Params
  const contractName = contract.name
  // Path to the compiled contract JSON
  const contractJsonPath = path.join(
    process.cwd(),
    'out',
    `${contractName}.sol`,
    `${contractName}.json`,
  )

  if (!fs.existsSync(contractJsonPath)) {
    throw new Error(`Contract JSON file not found: ${contractJsonPath}`)
  }

  // Read the contract JSON file
  const contractJson = JSON.parse(fs.readFileSync(contractJsonPath, 'utf8'))

  // Extract bytecode from the JSON
  const bytecode = contractJson.bytecode.object as Hex

  if (!bytecode || bytecode === '0x') {
    throw new Error(`Bytecode is empty for ${contractName}`)
  }
  // Encode the deployment data
  // The deployment data includes the bytecode and constructor arguments
  const deploymentBytecode = encodeDeployData({
    abi: contractJson.abi,
    bytecode,
    args: contract.args,
  })

  // Encode the function call to deploy
  const deployBytecode = encodeFunctionData({
    abi: CREATE_X_ABI,
    functionName: 'deployCreate2',
    args: [salt, deploymentBytecode],
  })

  const encodedArgs = encodeAbiParameters(
    contractJson.abi[0].inputs, // Assuming the first item in the ABI is the constructor
    contract.args,
  )

  return {
    contractName,
    salt,
    initCodeHash: keccak256(deploymentBytecode),
    args: contract.args,
    encodedArgs,
    deployBytecode,
  }
}

/**
 * Saves deployment data to a JSON file
 * @param deploymentData The deployment data to save
 * @param outputPath The path to save the JSON file to
 */
export function saveDeploymentData(
  deploymentData: Record<string, any>,
  outputPath: string = 'bytecode_deployment.json',
): void {
  // Ensure directory exists
  const directory = path.dirname(outputPath)
  if (!fs.existsSync(directory)) {
    fs.mkdirSync(directory, { recursive: true })
    console.log(`Created directory: ${directory}`)
  }

  // Delete the file if it exists
  if (fs.existsSync(outputPath)) {
    fs.unlinkSync(outputPath)
    console.log(`Deleted existing file: ${outputPath}`)
  }

  // Create and write to the file
  fs.writeFileSync(outputPath, JSON.stringify(deploymentData, null, 2))
  console.log(`Deployment data saved to ${outputPath}`)
}

/**
 * Fetches chain IDs from the deployment data URL using fetch API
 * @returns Array of available chain IDs
 * @throws Error if unable to fetch or parse deployment data
 */
export async function fetchDeployData(): Promise<string[]> {
  // Get the URL from environment or use default
  const CHAIN_DATA_URL =
    process.env.CHAIN_DATA_URL || PATHS.DEFAULT_CHAIN_DATA_URL

  console.log(`Fetching deployment data from ${CHAIN_DATA_URL}...`)

  try {
    // Use native fetch API (available in Node.js v18+)

    // Fetch the data
    const response = await fetch(CHAIN_DATA_URL)

    if (!response.ok) {
      throw new Error(`HTTP error! Status: ${response.status}`)
    }

    // Parse the JSON
    const deployData = await response.json()
    const chainIds = Object.keys(deployData)

    if (chainIds.length > 0) {
      console.log(
        `Found ${chainIds.length} chain IDs in deployment data: ${chainIds.join(', ')}`,
      )
      return chainIds
    } else {
      throw new Error('No chain IDs found in deployment data')
    }
  } catch (error) {
    console.error('Error fetching or parsing deployment data:', error)
    throw new Error(
      `Failed to fetch or parse deployment data from ${'DEPLOY_DATA_URL'}: ${(error as Error).message}`,
    )
  }
}
