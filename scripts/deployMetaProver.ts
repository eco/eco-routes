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

    // Create trusted provers array with properly structured objects
    const trustedProvers = [] // Empty initially, will be configured later
    // Example of how to add trusted provers if needed:
    // const trustedProvers = [
    //   { chainId: 1, prover: "0x1234..." },
    //   { chainId: 10, prover: "0x5678..." }
    // ];
    
    // Validate chain IDs if any trusted provers are added
    for (const prover of trustedProvers) {
      if (!prover.chainId || prover.chainId <= 0) {
        throw new Error(`Invalid chain ID in trusted prover: ${prover.chainId}`);
      }
    }

    const metaProverTx = await metaProverFactory.getDeployTransaction(
      deployNetwork.metalayerRouterAddress,
      inboxAddress,
      trustedProvers, // TrustedProver[] struct array
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
    await run('verify:verify', {
      address: metaProverAddress,
      constructorArguments: [
        deployNetwork.metalayerRouterAddress,
        inboxAddress,
        trustedProvers, // TrustedProver[] struct array
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
  
  2. For production systems, configure trusted provers with chain IDs:
     - metaProver.addTrustedProvers([
         { chainId: 1, prover: "0x1234..." },
         { chainId: 10, prover: "0x5678..." }
       ])
  
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
