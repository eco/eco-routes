import { TronToolkit, DeploymentConfig, LogLevel } from '../src'
import * as fs from 'fs'
import * as path from 'path'
import * as dotenv from 'dotenv'

// Load environment variables
dotenv.config({ path: path.join(__dirname, '../../.env') })

async function deployContracts() {
  const chainId = process.env.TRON_CHAINID

  if (!chainId) {
    console.error('Error: CHAINID environment variable is required')
    console.error(
      '   Set CHAINID=728126428 for mainnet or CHAINID=2494104990 for testnet',
    )
    process.exit(1)
  }

  // Determine network based on chain ID
  const network = chainId === '728126428' ? 'mainnet' : 'testnet'
  const networkName =
    chainId === '728126428' ? 'Tron Mainnet' : 'Tron Testnet (Shasta)'

  console.log('Portal & LayerZeroProver Contract Deployment')
  console.log('============================================')
  console.log(`Target Network: ${networkName} (Chain ID: ${chainId})`)
  console.log('')

  // Get the appropriate private key for the network
  const privateKey = process.env.TRON_PRIVATE_KEY

  if (!privateKey) {
    console.error('Error: TRON_PRIVATE_KEY environment variable is required')
    process.exit(1)
  }

  // Initialize Tron Toolkit
  const toolkit = new TronToolkit({
    network: network as 'mainnet' | 'testnet',
    logLevel: LogLevel.INFO,
    privateKey,
  })

  try {
    // Check system health
    console.log('Checking system health...')
    const health = await toolkit.healthCheck()

    if (!health.network.isHealthy) {
      console.error('Network health check failed')
      console.error('   Network is not responding properly')
      process.exit(1)
    }

    console.log('Network is healthy')
    console.log(`   Block Height: ${health.blockHeight}`)
    console.log(`   Account: ${health.account.address}`)
    console.log(`   Balance: ${health.account.balance.toFixed(6)} TRX`)
    console.log('')

    // Read Portal artifact
    console.log('Loading Portal contract artifact...')
    const artifactPath = path.join(
      __dirname,
      '../../tronbox/build/contracts/Portal.json',
    )

    if (!fs.existsSync(artifactPath)) {
      console.error('Error: Portal artifact not found')
      console.error(
        '   Please run: npm run forge-to-tronbox out/Portal.sol/Portal.json',
      )
      process.exit(1)
    }

    const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'))
    console.log(`Loaded ${artifact.contractName} artifact`)
    console.log(`   ABI Functions: ${artifact.abi.length}`)
    console.log(
      `   Bytecode Size: ${Math.floor(artifact.bytecode.length / 2)} bytes`,
    )
    console.log('')

    // Prepare deployment configuration
    const deploymentConfig: DeploymentConfig = {
      contractName: artifact.contractName,
      bytecode: artifact.bytecode,
      abi: artifact.abi,
      constructorParams: [], // Portal constructor takes no parameters
      feeLimit: 1000000000, // 1000 TRX fee limit
    }

    // Predict resource requirements
    console.log('Predicting deployment resources...')
    const resourcePrediction = await toolkit.predictContractDeployment(
      deploymentConfig.bytecode,
      deploymentConfig.constructorParams,
      deploymentConfig.abi,
    )

    console.log('Resource Requirements:')
    console.log(`   Energy: ${resourcePrediction.energy.toLocaleString()}`)
    console.log(
      `   Bandwidth: ${resourcePrediction.bandwidth.toLocaleString()}`,
    )
    console.log(
      `   Estimated Cost: ${resourcePrediction.totalCostTRX.toFixed(6)} TRX`,
    )
    console.log(
      `   Confidence: ${(resourcePrediction.confidence * 100).toFixed(1)}%`,
    )
    console.log('')

    // Check current account resources
    console.log('Checking account resources...')
    const currentResources = await toolkit.getAccountResources()
    const currentBalance = await toolkit.getBalance()

    console.log('Current Resources:')
    console.log(
      `   Available Energy: ${currentResources.energy.available.toLocaleString()}`,
    )
    console.log(
      `   Available Bandwidth: ${currentResources.bandwidth.available.toLocaleString()}`,
    )
    console.log(`   TRX Balance: ${currentBalance.toFixed(6)} TRX`)
    console.log('')

    // Determine if we need to rent resources
    const energyDeficit = Math.max(
      0,
      resourcePrediction.energy - currentResources.energy.available,
    )
    const bandwidthDeficit = Math.max(
      0,
      resourcePrediction.bandwidth - currentResources.bandwidth.available,
    )
    const needsRental = energyDeficit > 0 || bandwidthDeficit > 0

    if (needsRental) {
      console.log('Resource rental required...')
      console.log(`   Need to rent ${energyDeficit.toLocaleString()} energy`)
      console.log(
        `   Need to rent ${bandwidthDeficit.toLocaleString()} bandwidth`,
      )

      try {
        // Auto-rent resources with safety margin
        const rental = await toolkit.autoRentResources(
          energyDeficit,
          bandwidthDeficit,
          toolkit.getCurrentAddress(),
          0.3, // 30% safety margin for deployment
        )

        if (rental.success) {
          console.log('Successfully rented resources')
          console.log(
            `   Total rental cost: ${rental.totalCost.toFixed(6)} TRX`,
          )

          if (rental.energyRental) {
            console.log(
              `   Energy rental: ${rental.energyRental.transactionId}`,
            )
          }
          if (rental.bandwidthRental) {
            console.log(
              `   Bandwidth rental: ${rental.bandwidthRental.transactionId}`,
            )
          }
        } else {
          console.error('Failed to rent required resources')
          console.error(
            '   Please ensure you have sufficient TRX and TronZap API access',
          )
          process.exit(1)
        }
      } catch (error) {
        console.warn(
          'Resource rental failed, proceeding with deployment anyway',
        )
        console.warn('   Deployment may fail if resources are insufficient')
        console.warn(`   Error: ${error}`)
      }
    } else {
      console.log('Sufficient resources available, no rental needed')
    }

    console.log('')
    console.log('Deploying Portal contract...')
    console.log('=============================')

    // Deploy the contract
    const startTime = Date.now()
    const deploymentResult = await toolkit.deployContract(
      deploymentConfig,
      undefined, // Use default private key from environment
      false, // Don't auto-rent (we handled it manually above)
    )

    const deploymentTime = Date.now() - startTime

    console.log('')
    console.log('Portal deployment completed successfully!')
    console.log('=======================================')
    console.log(`Contract Address: ${deploymentResult.contractAddress}`)
    console.log(`Transaction ID: ${deploymentResult.transactionId}`)
    console.log(`Block Number: ${deploymentResult.blockNumber}`)
    console.log(`Energy Used: ${deploymentResult.energyUsed.toLocaleString()}`)
    console.log(
      `Bandwidth Used: ${deploymentResult.bandwidthUsed.toLocaleString()}`,
    )
    console.log(`Actual Cost: ${deploymentResult.actualCost.toFixed(6)} TRX`)
    console.log(
      `Deployment Time: ${(deploymentTime / 1000).toFixed(1)} seconds`,
    )
    console.log('')

    // Compare prediction vs actual
    console.log('Prediction Accuracy:')
    console.log('==================')
    const energyAccuracy =
      deploymentResult.energyUsed > 0
        ? (1 -
            Math.abs(resourcePrediction.energy - deploymentResult.energyUsed) /
              deploymentResult.energyUsed) *
          100
        : 100
    const bandwidthAccuracy =
      deploymentResult.bandwidthUsed > 0
        ? (1 -
            Math.abs(
              resourcePrediction.bandwidth - deploymentResult.bandwidthUsed,
            ) /
              deploymentResult.bandwidthUsed) *
          100
        : 100

    console.log(`Energy Prediction: ${energyAccuracy.toFixed(1)}% accurate`)
    console.log(
      `Bandwidth Prediction: ${bandwidthAccuracy.toFixed(1)}% accurate`,
    )
    console.log('')

    // Verify deployment
    console.log('Verifying deployment...')
    try {
      const contractInfo = await toolkit
        .getTronWeb()
        .trx.getContract(deploymentResult.contractAddress)
      if (contractInfo && contractInfo.bytecode) {
        console.log('Contract verification successful')
        console.log(`   Contract bytecode found on chain`)
      } else {
        console.warn('Contract verification failed - no bytecode found')
      }
    } catch (error) {
      console.warn('Could not verify contract deployment:', error)
    }

    console.log('')
    console.log('Next Steps:')
    console.log('==========')
    console.log(`1. Save contract address: ${deploymentResult.contractAddress}`)
    console.log(
      `2. Verify on TronScan: https://${network === 'testnet' ? 'nile.' : ''}tronscan.org/#/contract/${deploymentResult.contractAddress}`,
    )
    console.log(`3. Test contract functionality`)
    console.log(`4. Update deployment records`)

    // Save deployment info to file
    const deploymentInfo = {
      network: networkName,
      chainId,
      contractName: 'Portal',
      contractAddress: deploymentResult.contractAddress,
      transactionId: deploymentResult.transactionId,
      blockNumber: deploymentResult.blockNumber,
      deployedAt: new Date().toISOString(),
      energyUsed: deploymentResult.energyUsed,
      bandwidthUsed: deploymentResult.bandwidthUsed,
      actualCost: deploymentResult.actualCost,
      deploymentTimeMs: deploymentTime,
    }

    const deploymentFile = path.join(
      __dirname,
      `../deployments/portal-${network}-${chainId}.json`,
    )
    const deploymentDir = path.dirname(deploymentFile)

    if (!fs.existsSync(deploymentDir)) {
      fs.mkdirSync(deploymentDir, { recursive: true })
    }

    fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2))
    console.log(`5. Deployment info saved to: ${deploymentFile}`)

    // Now deploy LayerZeroProver
    console.log('')
    console.log('========================================')
    console.log('Deploying LayerZeroProver contract...')
    console.log('========================================')
    console.log('')

    // LayerZero endpoint addresses
    const layerZeroEndpoints = {
      mainnet: '0x0Af59750D5dB5460E5d89E268C474d5F7407c061', // Tron Mainnet LayerZero endpoint
      testnet: '0x1b356f3030CE0c1eF9D3e1E250Bf0BB11D81b2d1', // Tron Testnet LayerZero endpoint
    }

    const endpointAddress =
      layerZeroEndpoints[network as keyof typeof layerZeroEndpoints]

    // Parse solvers from environment variable
    const solversEnv = process.env.TRON_SOLVERS
    if (!solversEnv) {
      console.error('Error: TRON_SOLVERS environment variable is required')
      console.error(
        '   Set TRON_SOLVERS to comma-separated list of solver addresses',
      )
      process.exit(1)
    }

    const solvers = solversEnv.split(',').map((addr) => addr.trim())
    console.log('LayerZero Configuration:')
    console.log(`   Portal Address: ${deploymentResult.contractAddress}`)
    console.log(`   Endpoint Address: ${endpointAddress}`)
    console.log(`   Solvers: ${solvers.join(', ')}`)
    console.log('')

    // Read LayerZeroProver artifact
    console.log('Loading LayerZeroProver contract artifact...')
    const lzArtifactPath = path.join(
      __dirname,
      '../../tronbox/build/contracts/LayerZeroProver.json',
    )

    if (!fs.existsSync(lzArtifactPath)) {
      console.error('Error: LayerZeroProver artifact not found')
      console.error(
        '   Please run: npm run forge-to-tronbox out/LayerZeroProver.sol/LayerZeroProver.json',
      )
      process.exit(1)
    }

    const lzArtifact = JSON.parse(fs.readFileSync(lzArtifactPath, 'utf8'))
    console.log(`Loaded ${lzArtifact.contractName} artifact`)
    console.log(`   ABI Functions: ${lzArtifact.abi.length}`)
    console.log(
      `   Bytecode Size: ${Math.floor(lzArtifact.bytecode.length / 2)} bytes`,
    )
    console.log('')

    // Prepare LayerZeroProver deployment configuration
    const lzDeploymentConfig: DeploymentConfig = {
      contractName: lzArtifact.contractName,
      bytecode: lzArtifact.bytecode,
      abi: lzArtifact.abi,
      constructorParams: [
        deploymentResult.contractAddress, // portal address
        solvers, // solvers array
        endpointAddress, // LayerZero endpoint
        200000, // minGasLimit
      ],
      feeLimit: 1000000000, // 1000 TRX fee limit
    }

    // Predict LayerZeroProver resource requirements
    console.log('Predicting LayerZeroProver deployment resources...')
    const lzResourcePrediction = await toolkit.predictContractDeployment(
      lzDeploymentConfig.bytecode,
      lzDeploymentConfig.constructorParams,
      lzDeploymentConfig.abi,
    )

    console.log('LayerZeroProver Resource Requirements:')
    console.log(`   Energy: ${lzResourcePrediction.energy.toLocaleString()}`)
    console.log(
      `   Bandwidth: ${lzResourcePrediction.bandwidth.toLocaleString()}`,
    )
    console.log(
      `   Estimated Cost: ${lzResourcePrediction.totalCostTRX.toFixed(6)} TRX`,
    )
    console.log(
      `   Confidence: ${(lzResourcePrediction.confidence * 100).toFixed(1)}%`,
    )
    console.log('')

    // Check if we need additional resources for LayerZeroProver
    const currentResourcesLZ = await toolkit.getAccountResources()
    const lzEnergyDeficit = Math.max(
      0,
      lzResourcePrediction.energy - currentResourcesLZ.energy.available,
    )
    const lzBandwidthDeficit = Math.max(
      0,
      lzResourcePrediction.bandwidth - currentResourcesLZ.bandwidth.available,
    )
    const lzNeedsRental = lzEnergyDeficit > 0 || lzBandwidthDeficit > 0

    if (lzNeedsRental) {
      console.log('Additional resource rental required for LayerZeroProver...')
      console.log(`   Need to rent ${lzEnergyDeficit.toLocaleString()} energy`)
      console.log(
        `   Need to rent ${lzBandwidthDeficit.toLocaleString()} bandwidth`,
      )

      try {
        const lzRental = await toolkit.autoRentResources(
          lzEnergyDeficit,
          lzBandwidthDeficit,
          toolkit.getCurrentAddress(),
          0.3, // 30% safety margin
        )

        if (lzRental.success) {
          console.log('Successfully rented additional resources')
          console.log(
            `   Additional rental cost: ${lzRental.totalCost.toFixed(6)} TRX`,
          )
        } else {
          console.error(
            'Failed to rent additional resources for LayerZeroProver',
          )
          process.exit(1)
        }
      } catch (error) {
        console.warn(
          'LayerZeroProver resource rental failed, proceeding anyway',
        )
        console.warn(`   Error: ${error}`)
      }
    } else {
      console.log(
        'Sufficient resources available for LayerZeroProver deployment',
      )
    }

    console.log('')
    console.log('Deploying LayerZeroProver contract...')
    console.log('====================================')

    // Deploy LayerZeroProver
    const lzStartTime = Date.now()
    const lzDeploymentResult = await toolkit.deployContract(
      lzDeploymentConfig,
      undefined, // Use default private key
      false, // Don't auto-rent (handled manually)
    )

    const lzDeploymentTime = Date.now() - lzStartTime

    console.log('')
    console.log('LayerZeroProver deployment completed successfully!')
    console.log('================================================')
    console.log(`Contract Address: ${lzDeploymentResult.contractAddress}`)
    console.log(`Transaction ID: ${lzDeploymentResult.transactionId}`)
    console.log(`Block Number: ${lzDeploymentResult.blockNumber}`)
    console.log(
      `Energy Used: ${lzDeploymentResult.energyUsed.toLocaleString()}`,
    )
    console.log(
      `Bandwidth Used: ${lzDeploymentResult.bandwidthUsed.toLocaleString()}`,
    )
    console.log(`Actual Cost: ${lzDeploymentResult.actualCost.toFixed(6)} TRX`)
    console.log(
      `Deployment Time: ${(lzDeploymentTime / 1000).toFixed(1)} seconds`,
    )
    console.log('')

    // Verify LayerZeroProver deployment
    console.log('Verifying LayerZeroProver deployment...')
    try {
      const lzContractInfo = await toolkit
        .getTronWeb()
        .trx.getContract(lzDeploymentResult.contractAddress)
      if (lzContractInfo && lzContractInfo.bytecode) {
        console.log('LayerZeroProver verification successful')
        console.log('   Contract bytecode found on chain')
      } else {
        console.warn('LayerZeroProver verification failed - no bytecode found')
      }
    } catch (error) {
      console.warn('Could not verify LayerZeroProver deployment:', error)
    }

    // Save LayerZeroProver deployment info
    const lzDeploymentInfo = {
      network: networkName,
      chainId,
      contractName: 'LayerZeroProver',
      contractAddress: lzDeploymentResult.contractAddress,
      transactionId: lzDeploymentResult.transactionId,
      blockNumber: lzDeploymentResult.blockNumber,
      deployedAt: new Date().toISOString(),
      energyUsed: lzDeploymentResult.energyUsed,
      bandwidthUsed: lzDeploymentResult.bandwidthUsed,
      actualCost: lzDeploymentResult.actualCost,
      deploymentTimeMs: lzDeploymentTime,
      constructorParams: {
        portalAddress: deploymentResult.contractAddress,
        solvers,
        endpointAddress,
        minGasLimit: 200000,
      },
    }

    const lzDeploymentFile = path.join(
      __dirname,
      `../deployments/layerzero-prover-${network}-${chainId}.json`,
    )
    fs.writeFileSync(
      lzDeploymentFile,
      JSON.stringify(lzDeploymentInfo, null, 2),
    )

    console.log('')
    console.log('========================================')
    console.log('DEPLOYMENT SUMMARY')
    console.log('========================================')
    console.log('')
    console.log('Portal Contract:')
    console.log(`   Address: ${deploymentResult.contractAddress}`)
    console.log(`   Cost: ${deploymentResult.actualCost.toFixed(6)} TRX`)
    console.log('')
    console.log('LayerZeroProver Contract:')
    console.log(`   Address: ${lzDeploymentResult.contractAddress}`)
    console.log(`   Cost: ${lzDeploymentResult.actualCost.toFixed(6)} TRX`)
    console.log('')
    const totalCost =
      deploymentResult.actualCost + lzDeploymentResult.actualCost
    console.log(`Total Deployment Cost: ${totalCost.toFixed(6)} TRX`)
    console.log('')
    console.log('Next Steps:')
    console.log('1. Update your configuration files with these addresses')
    console.log(`2. Verify contracts on TronScan:`)
    console.log(
      `   - Portal: https://${network === 'testnet' ? 'nile.' : ''}tronscan.org/#/contract/${deploymentResult.contractAddress}`,
    )
    console.log(
      `   - LayerZeroProver: https://${network === 'testnet' ? 'nile.' : ''}tronscan.org/#/contract/${lzDeploymentResult.contractAddress}`,
    )
    console.log('3. Test contract interactions')
    console.log('')
    console.log('Deployment info saved to:')
    console.log(`   Portal: ${deploymentFile}`)
    console.log(`   LayerZeroProver: ${lzDeploymentFile}`)
  } catch (error) {
    console.error('')
    console.error('Contract deployment failed!')
    console.error('=========================')
    console.error(`Error: ${error}`)

    if (error instanceof Error) {
      console.error(`Stack: ${error.stack}`)
    }

    process.exit(1)
  } finally {
    toolkit.cleanup()
  }
}

// Run deployment if this file is executed directly
if (require.main === module) {
  deployContracts().catch(console.error)
}

export { deployContracts }
