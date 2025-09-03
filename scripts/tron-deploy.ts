import { TronWeb } from 'tronweb'
import type { ContractAbiInterface } from 'tronweb/lib/esm/types/ABI'
import fs from 'fs'
import path from 'path'
import 'dotenv/config'

// TRON Chain IDs
const TRON_MAINNET_CHAIN_ID = 728126428
const TRON_SHASTA_CHAIN_ID = 2494104990
const TRON_NILE_CHAIN_ID = 3448148188

interface ContractArtifact {
  abi: any[]
  bytecode: string
}

interface DeploymentContext {
  existingPortal?: string
  layerZeroEndpoint?: string
  layerZeroDelegate?: string
  polymerCrossL2ProverV2?: string
  deployFilePath: string
  layerZeroCrossVmProvers: string[]
  polymerCrossVmProvers: string[]
  deployer: string
  contracts: {
    portal?: string
    layerZeroProver?: string
    polymerProver?: string
  }
}

class TronDeployer {
  private tronWeb: TronWeb
  private deploymentContext: DeploymentContext

  constructor() {
    // Clean private key - remove 0x prefix if present
    let privateKey = process.env.PRIVATE_KEY || ''
    if (privateKey.startsWith('0x')) {
      privateKey = privateKey.slice(2)
    }

    this.tronWeb = new TronWeb({
      fullHost:
        process.env.TRON_RPC_URL ||
        process.env.TRON_SHASTA_RPC_URL ||
        'https://api.shasta.trongrid.io',
      privateKey,
    })

    this.deploymentContext = {
      existingPortal: process.env.PORTAL_CONTRACT,
      layerZeroEndpoint: process.env.LAYERZERO_ENDPOINT,
      layerZeroDelegate: process.env.LAYERZERO_DELEGATE,
      polymerCrossL2ProverV2: process.env.POLYMER_CROSS_L2_PROVER_V2,
      deployFilePath: process.env.DEPLOY_FILE || 'out/deploy.csv',
      layerZeroCrossVmProvers: this.parseProvers(
        process.env.LAYERZERO_CROSS_VM_PROVERS,
      ),
      polymerCrossVmProvers: this.parseProvers(
        process.env.POLYMER_CROSS_VM_PROVERS,
      ),
      deployer: '',
      contracts: {},
    }
  }

  private parseProvers(proversString?: string): string[] {
    if (!proversString) return []
    return proversString
      .split(',')
      .map((p) => p.trim())
      .filter((p) => p.length > 0)
  }

  async init(): Promise<void> {
    // Set deployer address from private key
    let privateKey = process.env.PRIVATE_KEY || ''
    if (privateKey.startsWith('0x')) {
      privateKey = privateKey.slice(2)
    }
    const account = this.tronWeb.address.fromPrivateKey(privateKey)
    this.deploymentContext.deployer = account || ''
    console.log('Deployer address:', this.deploymentContext.deployer)

    // Determine network based on the RPC URL being used
    const rpcUrl =
      process.env.TRON_RPC_URL ||
      process.env.TRON_SHASTA_RPC_URL ||
      'https://api.shasta.trongrid.io'
    let network = 'unknown'
    if (rpcUrl.includes('api.trongrid.io')) {
      network = 'mainnet'
    } else if (rpcUrl.includes('shasta')) {
      network = 'shasta'
    } else if (rpcUrl.includes('nile')) {
      network = 'nile'
    }
    console.log('Using RPC URL:', rpcUrl)
    console.log('Connected to TRON network:', network)
  }

  private getNetworkName(nodeInfo: any): string {
    // Check node info to determine network
    if (
      nodeInfo.configNodeInfo?.p2pVersion?.includes('mainnet') ||
      nodeInfo.machineInfo?.memorySize > 1000000000
    ) {
      // Heuristic for mainnet
      return 'mainnet'
    } else if (
      nodeInfo.configNodeInfo?.p2pVersion?.includes('shasta') ||
      nodeInfo.beginSyncNum < 1000000
    ) {
      // Heuristic for testnet
      return 'shasta'
    } else {
      return 'nile'
    }
  }

  private loadContract(contractName: string): ContractArtifact {
    let artifactPath: string

    // Special path handling for prover contracts
    if (contractName.includes('Prover')) {
      artifactPath = path.join(
        __dirname,
        '..',
        'artifacts',
        'contracts',
        'prover',
        `${contractName}.sol`,
        `${contractName}.json`,
      )
    } else {
      artifactPath = path.join(
        __dirname,
        '..',
        'artifacts',
        'contracts',
        `${contractName}.sol`,
        `${contractName}.json`,
      )
    }

    if (!fs.existsSync(artifactPath)) {
      throw new Error(`Contract artifact not found: ${artifactPath}`)
    }

    const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'))

    // Helper function to check if a parameter has complex types that TronWeb can't handle
    const hasComplexTypes = (inputs: any[]): boolean => {
      return inputs.some(
        (input: any) =>
          input.type === 'tuple' ||
          input.internalType?.includes('struct') ||
          input.internalType?.includes('contract ') ||
          input.components, // nested tuple components
      )
    }

    // Filter out problematic items
    artifact.abi = artifact.abi.filter((item: any) => {
      // Keep constructor, events, and errors
      if (
        item.type === 'constructor' ||
        item.type === 'event' ||
        item.type === 'error'
      ) {
        return true
      }

      // For functions, filter out ones with complex parameter types
      if (item.type === 'function') {
        const hasComplexInputs = item.inputs && hasComplexTypes(item.inputs)
        const hasComplexOutputs = item.outputs && hasComplexTypes(item.outputs)

        // Keep simple functions, filter out complex ones
        return !hasComplexInputs && !hasComplexOutputs
      }

      return true
    })

    return artifact
  }

  private async deployContract(
    contractArtifact: ContractArtifact,
    constructorArgs: any[],
    contractName: string,
  ): Promise<string> {
    console.log(`Deploying ${contractName}...`)

    try {
      const contract = await this.tronWeb.contract().new({
        abi: contractArtifact.abi,
        bytecode: contractArtifact.bytecode,
        feeLimit: 1000000000, // 1000 TRX
        callValue: 0,
        userFeePercentage: 100,
        parameters: constructorArgs,
      })

      const deployedAddress = this.tronWeb.address.fromHex(
        contract.address as string,
      )
      console.log(`${contractName} deployed at: ${deployedAddress}`)

      return deployedAddress
    } catch (error) {
      console.error(`Failed to deploy ${contractName}:`, error)
      throw error
    }
  }

  private async deployPortal(): Promise<string> {
    if (this.deploymentContext.existingPortal) {
      this.deploymentContext.contracts.portal =
        this.deploymentContext.existingPortal
      console.log(
        'Using existing Portal:',
        this.deploymentContext.existingPortal,
      )
      return this.deploymentContext.existingPortal
    }

    const portalContract = this.loadContract('Portal')
    const address = await this.deployContract(portalContract, [], 'Portal')
    this.deploymentContext.contracts.portal = address
    return address
  }

  private async deployLayerZeroProver(): Promise<string> {
    const layerZeroContract = this.loadContract('LayerZeroProver')
    const minGasLimit = 200000

    // Constructor args (without self-reference for regular deployment)
    const constructorArgs = [
      this.deploymentContext.layerZeroEndpoint!,
      this.deploymentContext.layerZeroDelegate ||
        this.deploymentContext.deployer,
      this.deploymentContext.contracts.portal!,
      this.deploymentContext.layerZeroCrossVmProvers,
      minGasLimit,
    ]

    const address = await this.deployContract(
      layerZeroContract,
      constructorArgs,
      'LayerZeroProver',
    )
    this.deploymentContext.contracts.layerZeroProver = address
    return address
  }

  private async deployPolymerProver(): Promise<string> {
    const polymerContract = this.loadContract('PolymerProver')

    // Constructor args
    const constructorArgs = [
      this.deploymentContext.contracts.portal!,
      this.deploymentContext.polymerCrossL2ProverV2!,
      this.deploymentContext.polymerCrossVmProvers,
    ]

    const address = await this.deployContract(
      polymerContract,
      constructorArgs,
      'PolymerProver',
    )
    this.deploymentContext.contracts.polymerProver = address
    return address
  }

  private async writeDeploymentResults(): Promise<void> {
    const results: string[] = []

    // Get network info and map to chain ID
    let chainId = TRON_SHASTA_CHAIN_ID // Default
    try {
      const nodeInfo = await this.tronWeb.trx.getNodeInfo()
      const network = this.getNetworkName(nodeInfo)

      switch (network) {
        case 'mainnet':
          chainId = TRON_MAINNET_CHAIN_ID
          break
        case 'shasta':
          chainId = TRON_SHASTA_CHAIN_ID
          break
        case 'nile':
        default:
          chainId = TRON_NILE_CHAIN_ID
          break
      }
    } catch (error) {
      console.log('Could not detect network, using Nile chain ID')
    }

    for (const [contractType, address] of Object.entries(
      this.deploymentContext.contracts,
    )) {
      if (address) {
        let contractPath: string
        switch (contractType) {
          case 'portal':
            contractPath = 'contracts/Portal.sol:Portal'
            break
          case 'layerZeroProver':
            contractPath =
              'contracts/prover/LayerZeroProver.sol:LayerZeroProver'
            break
          case 'polymerProver':
            contractPath = 'contracts/prover/PolymerProver.sol:PolymerProver'
            break
          default:
            continue
        }

        results.push(`${chainId},${address},${contractPath},0x`)
      }
    }

    // Ensure output directory exists
    const outputDir = path.dirname(this.deploymentContext.deployFilePath)
    if (!fs.existsSync(outputDir)) {
      fs.mkdirSync(outputDir, { recursive: true })
    }

    fs.writeFileSync(
      this.deploymentContext.deployFilePath,
      results.join('\n') + '\n',
    )
    console.log(
      `Deployment results written to: ${this.deploymentContext.deployFilePath}`,
    )
  }

  async run(): Promise<void> {
    try {
      await this.init()

      console.log('Starting TRON deployment process...')

      const hasExistingPortal = !!this.deploymentContext.existingPortal
      const hasLayerZero = !!this.deploymentContext.layerZeroEndpoint
      const hasPolymer = !!this.deploymentContext.polymerCrossL2ProverV2
      const needsPortal = !hasExistingPortal && (hasLayerZero || hasPolymer)

      // Deploy Portal
      if (needsPortal) {
        await this.deployPortal()
      } else if (hasExistingPortal) {
        this.deploymentContext.contracts.portal =
          this.deploymentContext.existingPortal
        console.log(
          'Using existing Portal:',
          this.deploymentContext.existingPortal,
        )
      }

      // Deploy provers based on configuration
      if (hasLayerZero) {
        await this.deployLayerZeroProver()
      }

      if (hasPolymer) {
        await this.deployPolymerProver()
      }

      await this.writeDeploymentResults()

      console.log('TRON deployment completed successfully!')
    } catch (error) {
      console.error('TRON deployment failed:', error)
      throw error
    }
  }
}

// Main execution
async function main(): Promise<void> {
  const deployer = new TronDeployer()
  await deployer.run()
}

if (require.main === module) {
  main().catch(console.error)
}

export default TronDeployer
