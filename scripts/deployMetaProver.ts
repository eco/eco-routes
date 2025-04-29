import { ethers, run, network } from 'hardhat'
import { setTimeout } from 'timers/promises'
import { networks as testnetNetworks } from '../config/testnet/config'
import { networks as mainnetNetworks } from '../config/mainnet/config'

// Use the same salt pattern as other deployments
let salt: string
if (
  network.name.toLowerCase().includes('sepolia') ||
  network.name === 'ecoTestnet'
) {
  salt = 'TESTNET'
} else {
  salt = 'HANDOFF0'
}

// Configure these parameters before running this script
const inboxAddress = '' // Set this to your deployed Inbox address
let metaProverAddress = ''

console.log('Deploying to Network: ', network.name)
console.log(`Deploying with salt: ethers.keccak256(ethers.toUtf8bytes(${salt})`)
salt = ethers.keccak256(ethers.toUtf8Bytes(salt))

let deployNetwork: any
switch (network.name) {
  case 'optimismSepoliaBlockscout':
    deployNetwork = testnetNetworks.optimismSepolia
    break
  case 'baseSepolia':
    deployNetwork = testnetNetworks.baseSepolia
    break
  case 'ecoTestnet':
    deployNetwork = testnetNetworks.ecoTestnet
    break
  case 'optimism':
    deployNetwork = mainnetNetworks.optimism
    break
  case 'base':
    deployNetwork = mainnetNetworks.base
    break
  case 'helix':
    deployNetwork = mainnetNetworks.helix
    break
}

async function main() {
  const [deployer] = await ethers.getSigners()

  const singletonDeployer = await ethers.getContractAt(
    'Deployer',
    '0xfc91Ac2e87Cc661B674DAcF0fB443a5bA5bcD0a3',
  )

  let receipt
  console.log('Deploying contracts with the account:', deployer.address)
  console.log(`**************************************************`)

  if (inboxAddress === '') {
    console.error(
      'ERROR: You must set the inboxAddress before running this script',
    )
    // Don't use process.exit directly
    throw new Error('Missing inboxAddress configuration')
  }

  if (metaProverAddress === '') {
    const metaProverFactory = await ethers.getContractFactory('MetaProver')

    // IMPORTANT: You need to configure the Metalayer router address in your network config
    if (!deployNetwork.metalayerRouterAddress) {
      console.error(
        'ERROR: No Metalayer router address configured for this network',
      )
      console.log('Add metalayerRouterAddress to your network configuration')
      // Don't use process.exit directly
      throw new Error('Missing metalayerRouterAddress configuration')
    }

    console.log(
      `Using Metalayer router at: ${deployNetwork.metalayerRouterAddress}`,
    )

    // Create trusted provers array with addresses
    // IMPORTANT: This array should not be empty in a production deployment!
    // For testing purposes, you can use an empty array, but real deployments should include
    // trusted provers to ensure security.
    const trustedProvers: string[] = [] // Add production prover addresses here
    
    // Example of how to add trusted provers:
    // const trustedProvers = [
    //   "0x1234...",
    //   "0x5678..."
    // ];

    // Validate addresses and check whitelist size limit
    if (trustedProvers.length > 20) {
      throw new Error(`Too many trusted provers: ${trustedProvers.length}. Maximum allowed is 20.`)
    }
    
    for (const prover of trustedProvers) {
      if (!ethers.isAddress(prover)) {
        throw new Error(`Invalid address in trusted prover: ${prover}`)
      }
    }
    
    // Display warning if deploying with an empty whitelist
    if (trustedProvers.length === 0) {
      console.warn(`
      ⚠️ WARNING: Deploying with EMPTY whitelist ⚠️
      No provers will be whitelisted initially, which may prevent the contract from working correctly.
      Consider adding trusted provers before deployment as the whitelist is immutable and cannot be modified later.
      `)
    }

    const metaProverTx = await metaProverFactory.getDeployTransaction(
      deployNetwork.metalayerRouterAddress,
      inboxAddress,
      trustedProvers, // Array of whitelisted addresses
    )

    receipt = await singletonDeployer.deploy(metaProverTx.data, salt, {
      gasLimit: 1000000,
    })
    console.log('MetaProver deployed')

    metaProverAddress = (
      await singletonDeployer.queryFilter(
        singletonDeployer.filters.Deployed,
        receipt.blockNumber,
      )
    )[0].args.addr

    console.log(`MetaProver deployed to: ${metaProverAddress}`)
  }

  console.log('Waiting for 15 seconds for Bytecode to be on chain')
  await setTimeout(15000)

  try {
    // For verification, we need to use the same trustedProvers array that was used during deployment
    await run('verify:verify', {
      address: metaProverAddress,
      constructorArguments: [
        deployNetwork.metalayerRouterAddress,
        inboxAddress,
        [], // Use empty array for verification if no trusted provers were provided
      ],
    })
    console.log('MetaProver verified at:', metaProverAddress)
  } catch (e) {
    console.log(`Error verifying MetaProver`, e)
  }

  console.log(`
  -----------------------------------------------
  IMPORTANT NEXT STEPS AFTER DEPLOYMENT:
  -----------------------------------------------
  1. Configure the Inbox with the new MetaProver:
     - inbox.setProvers([hyperProverAddress, metaProverAddress])
  
  2. IMPORTANT: The whitelist is immutable and configured at deployment time.
     Make sure to include all required prover addresses in the trustedProvers 
     array when deploying, as they cannot be added later.
  
  3. Update your client applications to use either HyperProver or MetaProver
     based on your cross-chain messaging requirements
  
  4. Make sure to use proper chain ID validation for cross-chain messages
     to improve security
  -----------------------------------------------
  `)
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
