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
    process.exit(1)
  }

  if (metaProverAddress === '') {
    const metaProverFactory = await ethers.getContractFactory('MetaProver')

    // IMPORTANT: You need to configure the Metalayer router address in your network config
    if (!deployNetwork.metalayerRouterAddress) {
      console.error(
        'ERROR: No Metalayer router address configured for this network',
      )
      console.log('Add metalayerRouterAddress to your network configuration')
      process.exit(1)
    }

    console.log(
      `Using Metalayer router at: ${deployNetwork.metalayerRouterAddress}`,
    )

    const metaProverTx = await metaProverFactory.getDeployTransaction(
      deployNetwork.metalayerRouterAddress,
      inboxAddress,
      [], // Initialize with an empty trusted provers array - can be configured later
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
        [], // Empty trusted provers array used in constructor
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
  
  2. For production systems, configure trusted provers:
     - metaProver.addTrustedProvers([trusted_addresses])
  
  3. Update your client applications to use either HyperProver or MetaProver
     based on your cross-chain messaging requirements
  -----------------------------------------------
  `)
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
