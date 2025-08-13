import { TronToolkit, DeploymentConfig, LogLevel } from '../src'
import * as fs from 'fs'
import * as path from 'path'
import * as dotenv from 'dotenv'

// Load environment variables
dotenv.config({ path: path.join(__dirname, '../../.env') })

async function deployLayerZeroProver(targetNetwork?: string) {
  // Get network from command line argument or environment variable
  const network = targetNetwork || process.env.CHAINID || process.env.TRON_CHAINID 
  
  if (!network) {
    console.error('Error: Network must be specified')
    console.error('Usage:')
    console.error('  npm run deploy:layerzeroprover mainnet')
    console.error('  npm run deploy:layerzeroprover testnet')
    console.error('Or set CHAINID environment variable (728126428=mainnet, 2494104990=testnet)')
    process.exit(1)
  }

  // Normalize network input and determine chain ID
  let normalizedNetwork: string
  let chainId: string
  let networkName: string

  if (network === 'mainnet' || network === '728126428') {
    normalizedNetwork = 'mainnet'
    chainId = '728126428'
    networkName = 'Tron Mainnet'
  } else if (network === 'testnet' || network === 'shasta' || network === '2494104990') {
    normalizedNetwork = 'testnet'
    chainId = '2494104990'
    networkName = 'Tron Testnet (Shasta)'
  } else {
    console.error(`Error: Invalid network '${network}'`)
    console.error('Valid options: mainnet, testnet, shasta')
    process.exit(1)
  }

  console.log('LayerZeroProver Contract Deployment')
  console.log('==================================')
  console.log(`Target Network: ${networkName} (Chain ID: ${chainId})`)
  console.log('')

  // Get the Portal address from environment
  const portalAddress = process.env.TRON_PORTAL
  if (!portalAddress) {
    console.error('Error: TRON_PORTAL environment variable is required')
    console.error('   Set TRON_PORTAL to the deployed Portal contract address')
    process.exit(1)
  }

  // Get the appropriate private key for the network
  const privateKey = process.env.TRON_PRIVATE_KEY

  if (!privateKey) {
    console.error('Error: TRON_PRIVATE_KEY environment variable is required')
    process.exit(1)
  }

  // Initialize Tron Toolkit
  const toolkit = new TronToolkit({
    network: normalizedNetwork as 'mainnet' | 'testnet',
    logLevel: LogLevel.INFO,
    privateKey,
  })

  // Derive deployer address from private key
  const deployerAddress = toolkit.getCurrentAddress()

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
    console.log(`   Balance: ${Number(health.account.balance).toFixed(6)} TRX`)
    console.log('')

    // LayerZero endpoint addresses
    const layerZeroEndpoints = {
      mainnet: '0x0Af59750D5dB5460E5d89E268C474d5F7407c061', // Tron Mainnet LayerZero endpoint
      testnet: '0x1b356f3030CE0c1eF9D3e1E250Bf0BB11D81b2d1', // Tron Testnet LayerZero endpoint
    }

    const endpointAddress =
      layerZeroEndpoints[normalizedNetwork as keyof typeof layerZeroEndpoints]

    // Parse provers from environment variable
    const proversEnv = process.env.TRON_PROVERS
    if (!proversEnv) {
      console.error('Error: TRON_PROVERS environment variable is required')
      console.error(
        '   Set TRON_PROVERS to comma-separated list of prover addresses',
      )
      process.exit(1)
    }

    const provers = proversEnv.split(',').map((addr) => addr.trim())
    
    console.log('LayerZero Configuration:')
    console.log(`   Portal Address: ${portalAddress}`)
    console.log(`   Endpoint Address: ${endpointAddress}`)
    console.log(`   Delegate Address: ${deployerAddress}`)
    console.log(`   Provers: ${provers.join(', ')}`)
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
        endpointAddress, // LayerZero endpoint
        deployerAddress, // delegate address
        portalAddress, // portal address
        provers, // provers array
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
      `   Estimated Cost: ${Number(lzResourcePrediction.totalCostTRX).toFixed(6)} TRX`,
    )
    console.log(
      `   Confidence: ${(lzResourcePrediction.confidence * 100).toFixed(1)}%`,
    )
    console.log('')

    // Check if we need resources for LayerZeroProver
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

    console.log('Checking account resources...')
    const currentBalance = await toolkit.getBalance()
    console.log('Current Resources:')
    console.log(
      `   Available Energy: ${currentResourcesLZ.energy.available.toLocaleString()}`,
    )
    console.log(
      `   Available Bandwidth: ${currentResourcesLZ.bandwidth.available.toLocaleString()}`,
    )
    console.log(`   TRX Balance: ${Number(currentBalance).toFixed(6)} TRX`)
    console.log('')

    if (lzNeedsRental) {
      console.log('Resource rental required for LayerZeroProver...')
      console.log(`   Need to rent ${lzEnergyDeficit.toLocaleString()} energy`)
      console.log(
        `   Need to rent ${lzBandwidthDeficit.toLocaleString()} bandwidth`,
      )

      if (normalizedNetwork === 'mainnet') {
        try {
          const lzRental = await toolkit.autoRentResources(
            lzEnergyDeficit,
            lzBandwidthDeficit,
            toolkit.getCurrentAddress(),
            0.3, // 30% safety margin
          )

          if (lzRental.success) {
            console.log('Successfully rented resources')
            console.log(
              `   Rental cost: ${Number(lzRental.totalCost).toFixed(6)} TRX`,
            )
          } else {
            console.error(
              'Failed to rent required resources for LayerZeroProver',
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
        console.log('Testnet deployment: Skipping TronZap rental for LayerZeroProver')
        console.log('   Note: This may cost more TRX than with energy rental')
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
    console.log(`Actual Cost: ${Number(lzDeploymentResult.actualCost).toFixed(6)} TRX`)
    console.log(
      `Deployment Time: ${(lzDeploymentTime / 1000).toFixed(1)} seconds`,
    )
    console.log('')

    // Compare prediction vs actual
    console.log('Prediction Accuracy:')
    console.log('==================')
    const energyAccuracy =
      lzDeploymentResult.energyUsed > 0
        ? (1 -
            Math.abs(lzResourcePrediction.energy - lzDeploymentResult.energyUsed) /
              lzDeploymentResult.energyUsed) *
          100
        : 100
    const bandwidthAccuracy =
      lzDeploymentResult.bandwidthUsed > 0
        ? (1 -
            Math.abs(
              lzResourcePrediction.bandwidth - lzDeploymentResult.bandwidthUsed,
            ) /
              lzDeploymentResult.bandwidthUsed) *
          100
        : 100

    console.log(`Energy Prediction: ${energyAccuracy.toFixed(1)}% accurate`)
    console.log(
      `Bandwidth Prediction: ${bandwidthAccuracy.toFixed(1)}% accurate`,
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
      actualCost: Number(lzDeploymentResult.actualCost),
      deploymentTimeMs: lzDeploymentTime,
      constructorParams: {
        endpointAddress,
        delegateAddress: deployerAddress,
        portalAddress,
        provers,
        minGasLimit: 200000,
      },
    }

    const lzDeploymentFile = path.join(
      __dirname,
      `../deployments/layerzero-prover-${normalizedNetwork}-${chainId}.json`,
    )
    const deploymentDir = path.dirname(lzDeploymentFile)

    if (!fs.existsSync(deploymentDir)) {
      fs.mkdirSync(deploymentDir, { recursive: true })
    }

    fs.writeFileSync(
      lzDeploymentFile,
      JSON.stringify(lzDeploymentInfo, null, 2),
    )

    console.log('')
    console.log('======================================')
    console.log('DEPLOYMENT SUMMARY')
    console.log('======================================')
    console.log('')
    console.log('LayerZeroProver Contract:')
    console.log(`   Address: ${lzDeploymentResult.contractAddress}`)
    console.log(`   Cost: ${Number(lzDeploymentResult.actualCost).toFixed(6)} TRX`)
    console.log(`   Portal: ${portalAddress}`)
    console.log(`   Endpoint: ${endpointAddress}`)
    console.log('')
    console.log('Next Steps:')
    console.log('1. Update your configuration files with this address')
    console.log(`2. Verify contract on TronScan:`)
    console.log(
      `   - LayerZeroProver: https://${normalizedNetwork === 'testnet' ? 'shasta.' : ''}tronscan.org/#/contract/${lzDeploymentResult.contractAddress}`,
    )
    console.log('3. Test contract interactions')
    console.log('')
    console.log('Deployment info saved to:')
    console.log(`   LayerZeroProver: ${lzDeploymentFile}`)
  } catch (error) {
    console.error('')
    console.error('LayerZeroProver deployment failed!')
    console.error('==================================')
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
  const targetNetwork = process.argv[2] // Get first command line argument
  deployLayerZeroProver(targetNetwork).catch(console.error)
}

export { deployLayerZeroProver }