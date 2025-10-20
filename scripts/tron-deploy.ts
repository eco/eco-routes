import { TronWeb } from 'tronweb'
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
      existingPortal: process.env.TRON_PORTAL_CONTRACT,
      layerZeroEndpoint: process.env.TRON_LAYERZERO_ENDPOINT,
      layerZeroDelegate: process.env.TRON_LAYERZERO_DELEGATE,
      polymerCrossL2ProverV2: process.env.TRON_POLYMER_CROSS_L2_PROVER_V2,
      deployFilePath: process.env.DEPLOY_FILE || 'out/deploy.csv',
      layerZeroCrossVmProvers: this.parseProvers(
        process.env.TRON_LAYERZERO_CROSS_VM_PROVERS,
      ),
      polymerCrossVmProvers: this.parseProvers(
        process.env.TRON_POLYMER_CROSS_VM_PROVERS,
      ),
      deployer: '',
      contracts: {},
    }
  }

  private parseProvers(proversString?: string): string[] {
    return proversString ? proversString
      .split(',')
      .map((p) => p.trim())
      .filter((p) => p.length > 0) : []
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
    }
    
    if (
      nodeInfo.configNodeInfo?.p2pVersion?.includes('shasta') ||
      nodeInfo.beginSyncNum < 1000000
    ) {
      // Heuristic for testnet
      return 'shasta'
    }

    return 'nile'
  }

  private loadContract(contractName: string): ContractArtifact {
    const artifactPath = path.join(
      __dirname,
      '..',
      'out',
      `${contractName}.sol`,
      `${contractName}.json`,
    )

    if (!fs.existsSync(artifactPath)) {
      throw new Error(`Contract artifact not found: ${artifactPath}`)
    }

    const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'))

    // Extract bytecode object if needed
    if (artifact.bytecode && typeof artifact.bytecode === 'object') {
      artifact.bytecode = artifact.bytecode.object
    }

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
    console.log(`ABI items: ${contractArtifact.abi.length}`)
    console.log(`Bytecode length: ${contractArtifact.bytecode.length}`)
    console.log(`Constructor args: ${JSON.stringify(constructorArgs)}`)

    try {
      // Use transaction builder directly to avoid ABI issues
      const tx = await this.tronWeb.transactionBuilder.createSmartContract({
        abi: contractArtifact.abi,
        bytecode: contractArtifact.bytecode,
        feeLimit: 5000000000, // 5000 TRX
        callValue: 0,
        userFeePercentage: 100,
        parameters: constructorArgs,
      })

      const signedTx = await this.tronWeb.trx.sign(tx)
      const broadcast = await this.tronWeb.trx.sendRawTransaction(signedTx)

      if (!broadcast.result) {
        throw new Error(`Broadcast failed: ${JSON.stringify(broadcast)}`)
      }

      console.log(`Transaction ID: ${broadcast.txid}`)

      // Wait for confirmation
      let receipt: any = null
      for (let i = 0; i < 30; i++) {
        await new Promise((resolve) => setTimeout(resolve, 2000))
        try {
          receipt = await this.tronWeb.trx.getTransactionInfo(broadcast.txid)
          if (receipt && receipt.id) {
            break
          }
        } catch (e) {
          // Transaction not yet confirmed
        }
      }

      if (!receipt || !receipt.contract_address) {
        throw new Error('Contract deployment failed or timed out')
      }

      const deployedAddress = this.tronWeb.address.fromHex(
        receipt.contract_address,
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

    // Default max log data size (128 KB)
    const maxLogDataSize = 131072

    // Constructor args
    const constructorArgs = [
      this.deploymentContext.contracts.portal!,
      this.deploymentContext.polymerCrossL2ProverV2!,
      maxLogDataSize,
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

    const results = Object.entries(this.deploymentContext.contracts)
      .filter(([, address]) => Boolean(address))
      .map(([contractType, address]) => {
        switch (contractType) {
          case 'portal':
            return `${chainId},${address},contracts/Portal.sol:Portal,0x`
          case 'layerZeroProver':
            return `${chainId},${address},contracts/prover/LayerZeroProver.sol:LayerZeroProver,0x`
          case 'polymerProver':
            return `${chainId},${address},contracts/prover/PolymerProver.sol:PolymerProver,0x`
          default:
            return `${chainId},${address},,0x`
        }
      })

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
      const hasPolymerConfig = !!this.deploymentContext.polymerCrossL2ProverV2

      // Deploy Portal if not existing
      if (!hasExistingPortal) {
        await this.deployPortal()
      } else {
        this.deploymentContext.contracts.portal =
          this.deploymentContext.existingPortal
        console.log(
          'Using existing Portal:',
          this.deploymentContext.existingPortal,
        )
      }

      // Deploy PolymerProver if configuration exists
      if (hasPolymerConfig) {
        await this.deployPolymerProver()
      } else {
        console.log('Skipping PolymerProver (no configuration provided)')
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
  return new TronDeployer().run()
}

if (require.main === module) {
  main().catch(console.error)
}

export default TronDeployer
