import { TronToolkit, DeploymentConfig, LogLevel } from '../src'
import { EnergyRentalManager } from '../src/rental/EnergyRentalManager'
import { TronZapClient } from '../src/rental/TronZapClient'
import * as fs from 'fs'
import * as path from 'path'
import * as dotenv from 'dotenv'

// Load environment variables
dotenv.config({ path: path.join(__dirname, '../../.env') })

async function deployContracts(targetNetwork?: string) {
  // Get network from command line argument or environment variable
  const network = targetNetwork || process.env.CHAINID || process.env.TRON_CHAINID 
  
  if (!network) {
    console.error('Error: Network must be specified')
    console.error('Usage:')
    console.error('  npm run deploy:portal-and-layerzeroprover mainnet')
    console.error('  npm run deploy:portal-and-layerzeroprover testnet')
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
    network: normalizedNetwork as 'mainnet' | 'testnet',
    logLevel: LogLevel.INFO,
    privateKey,
  })

  // Initialize energy rental manager for mainnet
  let energyRentalManager: EnergyRentalManager | undefined
  if (normalizedNetwork === 'mainnet') {
    try {
      const tronZapClient = new TronZapClient(process.env.TRONZAP_API_TOKEN, process.env.TRONZAP_API_SECRET)
      energyRentalManager = new EnergyRentalManager(tronZapClient)
      console.log('Energy rental manager initialized for mainnet deployment')
    } catch (error) {
      console.warn('TronZap API credentials missing - using fallback deployment mode')
      console.warn('Set TRONZAP_API_TOKEN and TRONZAP_API_SECRET for energy rental functionality')
      energyRentalManager = undefined // Disable rental manager for this deployment
    }
  }

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

    // Use actual observed usage from previous deployments for accurate rental calculations
    const PORTAL_ACTUAL_ENERGY_USAGE = 4471821 // From testnet deployment TGhZDJhuELXvnU2pHnVDLJ8UCzNg29aEHU
    const ENERGY_SAFETY_MARGIN = 1.02 // 2% safety margin for peace of mind
    const portalEnergyWithSafety = Math.floor(PORTAL_ACTUAL_ENERGY_USAGE * ENERGY_SAFETY_MARGIN)
    const adjustedEnergyNeeded = Math.max(resourcePrediction.energy, portalEnergyWithSafety)

    console.log('Resource Requirements:')
    console.log(`   Energy (predicted): ${resourcePrediction.energy.toLocaleString()}`)
    console.log(`   Energy (actual from testnet): ${PORTAL_ACTUAL_ENERGY_USAGE.toLocaleString()}`)
    console.log(`   Energy (with 2% safety margin): ${portalEnergyWithSafety.toLocaleString()}`)
    console.log(`   Energy (using for rental): ${adjustedEnergyNeeded.toLocaleString()}`)
    console.log(
      `   Bandwidth: ${resourcePrediction.bandwidth.toLocaleString()}`,
    )
    console.log(
      `   Estimated Cost: ${Number(resourcePrediction.totalCostTRX).toFixed(6)} TRX`,
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
    console.log(`   TRX Balance: ${Number(currentBalance).toFixed(6)} TRX`)
    console.log('')

    // Determine if we need to rent resources (using adjusted energy from actual usage)
    const energyDeficit = Math.max(
      0,
      adjustedEnergyNeeded - currentResources.energy.available,
    )
    const bandwidthDeficit = Math.max(
      0,
      resourcePrediction.bandwidth - currentResources.bandwidth.available,
    )
    const needsEnergyRental = energyDeficit > 0
    const needsBandwidthRental = bandwidthDeficit > 0

    // Handle resource rental using sophisticated energy rental manager
    if (normalizedNetwork === 'mainnet' && energyRentalManager && (needsEnergyRental || needsBandwidthRental)) {
      console.log('Mainnet deployment: Using energy rental manager for resource verification')
      
      const rentalOptions = {
        requiredEnergy: adjustedEnergyNeeded,
        requiredBandwidth: resourcePrediction.bandwidth,
        currentEnergy: currentResources.energy.available,
        currentBandwidth: currentResources.bandwidth.available,
        currentTrxBalance: Number(currentBalance),
        recipientAddress: deployerAddress,
        network: 'mainnet' as const
      }

      const rentalResult = await energyRentalManager.ensureSufficientEnergy(rentalOptions)

      if (!rentalResult.success) {
        console.error('')
        console.error('KABOOM! MAINNET ENERGY RENTAL FAILED')
        console.error('=================================')
        console.error(rentalResult.message)
        console.error('')
        console.error('Portal deployment CANCELLED.')
        process.exit(1)
      }

      if (rentalResult.totalCostTrx > 0) {
        console.log('ZING! Energy rental completed successfully')
        console.log(`   Rented Energy: ${rentalResult.rentedEnergy.toLocaleString()}`)
        console.log(`   Rented Bandwidth: ${rentalResult.rentedBandwidth.toLocaleString()}`)
        console.log(`   Total Cost: ${rentalResult.totalCostTrx.toFixed(6)} TRX`)
        if (rentalResult.energyRentalTxId) {
          console.log(`   Energy Rental TX: ${rentalResult.energyRentalTxId}`)
        }
        if (rentalResult.bandwidthRentalTxId) {
          console.log(`   Bandwidth Rental TX: ${rentalResult.bandwidthRentalTxId}`)
        }
      } else {
        console.log(rentalResult.message)
      }
    } else if (needsEnergyRental || needsBandwidthRental) {
      console.log('Resource analysis:')
      if (needsEnergyRental) {
        console.log(`   Energy deficit: ${energyDeficit.toLocaleString()}`)
      }
      if (needsBandwidthRental) {
        console.log(`   Bandwidth deficit: ${bandwidthDeficit.toLocaleString()}`)
      }

      if (normalizedNetwork === 'mainnet') {
        // Fallback protection if energy rental manager not available
        if (needsEnergyRental) {
          console.error('')
          console.error('WHOOSH! MAINNET ENERGY PROTECTION ACTIVATED')
          console.error('===========================================')
          console.error(`Energy required: ${adjustedEnergyNeeded.toLocaleString()}`)
          console.error(`Energy available: ${currentResources.energy.available.toLocaleString()}`)
          console.error(`Energy deficit: ${energyDeficit.toLocaleString()}`)
          console.error('')
          console.error('Deployment CANCELLED to prevent expensive TRX burning for energy.')
          console.error('Set TRONZAP_API_KEY for energy rental or increase account energy first.')
          process.exit(1)
        }
      } else {
        console.log('Testnet deployment: Skipping TronZap rental, using direct TRX payment')
        console.log('   Note: This may cost more TRX than with energy rental')
      }
    } else {
      console.log('Sufficient resources available, no rental needed')
    }

    // Verify energy levels before deployment if rental was attempted
    if (normalizedNetwork === 'mainnet' && energyRentalManager && (needsEnergyRental || needsBandwidthRental)) {
      console.log('Verifying energy levels before deployment...')
      
      const verification = await energyRentalManager.verifyEnergyAfterRental(
        adjustedEnergyNeeded,
        resourcePrediction.bandwidth,
        async () => await toolkit.getAccountResources()
      )

      if (!verification.success) {
        console.error('')
        console.error('BONK! POST-RENTAL ENERGY VERIFICATION FAILED')
        console.error('==========================================')  
        console.error(verification.message)
        console.error('')
        console.error('Portal deployment CANCELLED.')
        process.exit(1)
      }

      console.log('WOW! Post-rental energy verification passed')
      console.log(`   Available Energy: ${verification.availableEnergy.toLocaleString()}`)
      console.log(`   Available Bandwidth: ${verification.availableBandwidth.toLocaleString()}`)
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
    console.log(`Actual Cost: ${Number(deploymentResult.actualCost).toFixed(6)} TRX`)
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
      `2. Verify on TronScan: https://${normalizedNetwork === 'testnet' ? 'shasta.' : ''}tronscan.org/#/contract/${deploymentResult.contractAddress}`,
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
      actualCost: Number(deploymentResult.actualCost),
      deploymentTimeMs: deploymentTime,
    }

    const deploymentFile = path.join(
      __dirname,
      `../deployments/portal-${normalizedNetwork}-${chainId}.json`,
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
    console.log(`   Portal Address: ${deploymentResult.contractAddress}`)
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
        deploymentResult.contractAddress, // portal address
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

    // Use actual observed usage from previous deployments for accurate rental calculations
    const LAYERZERO_ACTUAL_ENERGY_USAGE = 1256807 // From testnet deployment TLXZJzz9MW43GhfnWhknE8ZG7pVPFJ4Qxd
    const lzEnergyWithSafety = Math.floor(LAYERZERO_ACTUAL_ENERGY_USAGE * ENERGY_SAFETY_MARGIN)
    const lzAdjustedEnergyNeeded = Math.max(lzResourcePrediction.energy, lzEnergyWithSafety)

    console.log('LayerZeroProver Resource Requirements:')
    console.log(`   Energy (predicted): ${lzResourcePrediction.energy.toLocaleString()}`)
    console.log(`   Energy (actual from testnet): ${LAYERZERO_ACTUAL_ENERGY_USAGE.toLocaleString()}`)
    console.log(`   Energy (with 2% safety margin): ${lzEnergyWithSafety.toLocaleString()}`)
    console.log(`   Energy (using for rental): ${lzAdjustedEnergyNeeded.toLocaleString()}`)
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

    // Check if we need additional resources for LayerZeroProver
    const currentResourcesLZ = await toolkit.getAccountResources()
    const lzEnergyDeficit = Math.max(
      0,
      lzAdjustedEnergyNeeded - currentResourcesLZ.energy.available,
    )
    const lzBandwidthDeficit = Math.max(
      0,
      lzResourcePrediction.bandwidth - currentResourcesLZ.bandwidth.available,
    )
    const lzNeedsEnergyRental = lzEnergyDeficit > 0
    const lzNeedsBandwidthRental = lzBandwidthDeficit > 0

    // Handle LayerZeroProver resource rental using energy rental manager
    if (normalizedNetwork === 'mainnet' && energyRentalManager && (lzNeedsEnergyRental || lzNeedsBandwidthRental)) {
      console.log('LayerZeroProver: Using energy rental manager for resource verification')
      
      const lzRentalOptions = {
        requiredEnergy: lzAdjustedEnergyNeeded,
        requiredBandwidth: lzResourcePrediction.bandwidth,
        currentEnergy: currentResourcesLZ.energy.available,
        currentBandwidth: currentResourcesLZ.bandwidth.available,
        currentTrxBalance: Number(await toolkit.getBalance()),
        recipientAddress: deployerAddress,
        network: 'mainnet' as const
      }

      const lzRentalResult = await energyRentalManager.ensureSufficientEnergy(lzRentalOptions)

      if (!lzRentalResult.success) {
        console.error('')
        console.error('BLAM! LAYERZERO PROVER ENERGY RENTAL FAILED')
        console.error('===========================================')
        console.error(lzRentalResult.message)
        console.error('')
        console.error('LayerZeroProver deployment CANCELLED.')
        process.exit(1)
      }

      if (lzRentalResult.totalCostTrx > 0) {
        console.log('BOOM! LayerZeroProver energy rental completed successfully')
        console.log(`   Rented Energy: ${lzRentalResult.rentedEnergy.toLocaleString()}`)
        console.log(`   Rented Bandwidth: ${lzRentalResult.rentedBandwidth.toLocaleString()}`)
        console.log(`   Total Cost: ${lzRentalResult.totalCostTrx.toFixed(6)} TRX`)
        if (lzRentalResult.energyRentalTxId) {
          console.log(`   Energy Rental TX: ${lzRentalResult.energyRentalTxId}`)
        }
        if (lzRentalResult.bandwidthRentalTxId) {
          console.log(`   Bandwidth Rental TX: ${lzRentalResult.bandwidthRentalTxId}`)
        }
      } else {
        console.log(lzRentalResult.message)
      }
    } else if (lzNeedsEnergyRental || lzNeedsBandwidthRental) {
      console.log('LayerZeroProver resource analysis:')
      if (lzNeedsEnergyRental) {
        console.log(`   Energy deficit: ${lzEnergyDeficit.toLocaleString()}`)
      }
      if (lzNeedsBandwidthRental) {
        console.log(`   Bandwidth deficit: ${lzBandwidthDeficit.toLocaleString()}`)
      }

      if (normalizedNetwork === 'mainnet') {
        // Fallback protection if energy rental manager not available
        if (lzNeedsEnergyRental) {
          console.error('')
          console.error('ZAP! MAINNET ENERGY PROTECTION ACTIVATED (LayerZeroProver)')
          console.error('=======================================================')
          console.error(`LayerZeroProver energy required: ${lzAdjustedEnergyNeeded.toLocaleString()}`)
          console.error(`Energy available: ${currentResourcesLZ.energy.available.toLocaleString()}`)
          console.error(`Energy deficit: ${lzEnergyDeficit.toLocaleString()}`)
          console.error('')
          console.error('LayerZeroProver deployment CANCELLED to prevent expensive TRX burning.')
          console.error('Set TRONZAP_API_KEY for energy rental or increase account energy first.')
          process.exit(1)
        }
      } else {
        console.log('Testnet deployment: Skipping additional TronZap rental for LayerZeroProver')
        console.log('   Note: This may cost more TRX than with energy rental')
      }
    } else {
      console.log(
        'Sufficient resources available for LayerZeroProver deployment',
      )
    }

    // Verify energy levels before LayerZeroProver deployment if rental was attempted
    if (normalizedNetwork === 'mainnet' && energyRentalManager && (lzNeedsEnergyRental || lzNeedsBandwidthRental)) {
      console.log('Verifying LayerZeroProver energy levels before deployment...')
      
      const lzVerification = await energyRentalManager.verifyEnergyAfterRental(
        lzAdjustedEnergyNeeded,
        lzResourcePrediction.bandwidth,
        async () => await toolkit.getAccountResources()
      )

      if (!lzVerification.success) {
        console.error('')
        console.error('CRASH! LAYERZERO PROVER POST-RENTAL ENERGY VERIFICATION FAILED')
        console.error('========================================================')  
        console.error(lzVerification.message)
        console.error('')
        console.error('LayerZeroProver deployment CANCELLED.')
        process.exit(1)
      }

      console.log('SWEET! LayerZeroProver post-rental energy verification passed')
      console.log(`   Available Energy: ${lzVerification.availableEnergy.toLocaleString()}`)
      console.log(`   Available Bandwidth: ${lzVerification.availableBandwidth.toLocaleString()}`)
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
        portalAddress: deploymentResult.contractAddress,
        provers,
        minGasLimit: 200000,
      },
    }

    const lzDeploymentFile = path.join(
      __dirname,
      `../deployments/layerzero-prover-${normalizedNetwork}-${chainId}.json`,
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
    console.log(`   Cost: ${Number(deploymentResult.actualCost).toFixed(6)} TRX`)
    console.log('')
    console.log('LayerZeroProver Contract:')
    console.log(`   Address: ${lzDeploymentResult.contractAddress}`)
    console.log(`   Cost: ${Number(lzDeploymentResult.actualCost).toFixed(6)} TRX`)
    console.log('')
    const totalCost =
      Number(deploymentResult.actualCost) + Number(lzDeploymentResult.actualCost)
    console.log(`Total Deployment Cost: ${totalCost.toFixed(6)} TRX`)
    console.log('')
    console.log('Next Steps:')
    console.log('1. Update your configuration files with these addresses')
    console.log(`2. Verify contracts on TronScan:`)
    console.log(
      `   - Portal: https://${normalizedNetwork === 'testnet' ? 'shasta.' : ''}tronscan.org/#/contract/${deploymentResult.contractAddress}`,
    )
    console.log(
      `   - LayerZeroProver: https://${normalizedNetwork === 'testnet' ? 'shasta.' : ''}tronscan.org/#/contract/${lzDeploymentResult.contractAddress}`,
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
  const targetNetwork = process.argv[2] // Get first command line argument
  deployContracts(targetNetwork).catch(console.error)
}

export { deployContracts }
