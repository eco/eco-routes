import { ethers, run, network } from 'hardhat'
import { setTimeout } from 'timers/promises'
// import { getAddress } from 'ethers'
// import c from '../config/testnet/config'
// import networks from '../config/testnet/config';
import { networks as testnetNetworks } from '../config/testnet/config'
import { networks as mainnetNetworks } from '../config/mainnet/config'

let salt: string
if (
  network.name.toLowerCase().includes('sepolia') ||
  network.name === 'ecoTestnet'
) {
  salt = 'TESTNET'
} else {
  //   salt = 'PROD'
  salt = 'HANDOFF0'
}

let inboxAddress = ''
let hyperProverAddress = ''

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
  default:
    throw new Error(
      `Network ${network.name} not configured with deployment settings`,
    )
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
    const inboxFactory = await ethers.getContractFactory('Inbox')

    const inboxTx = await inboxFactory.getDeployTransaction(
      deployer.address,
      true,
      [],
    )
    receipt = await singletonDeployer.deploy(inboxTx.data, salt, {
      gasLimit: 1000000,
    })
    console.log('inbox deployed')

    inboxAddress = (
      await singletonDeployer.queryFilter(
        singletonDeployer.filters.Deployed,
        receipt.blockNumber,
      )
    )[0].args.addr

    console.log(`inbox deployed to: ${inboxAddress}`)
  }

  if (hyperProverAddress === '' && inboxAddress !== '') {
    const hyperProverFactory = await ethers.getContractFactory('HyperProver')

    // IMPORTANT: The mailbox address is passed directly to the HyperProver constructor
    // This is the new configuration approach - we no longer need to separately set the mailbox
    // The HyperProver will use this mailbox for all cross-chain communication
    console.log(
      `Using Hyperlane mailbox at: ${deployNetwork.hyperlaneMailboxAddress}`,
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
        throw new Error(`Invalid chain ID in trusted prover: ${prover.chainId}`)
      }
    }

    const hyperProverTx = await hyperProverFactory.getDeployTransaction(
      deployNetwork.hyperlaneMailboxAddress,
      inboxAddress,
      trustedProvers, // TrustedProver[] struct array
    )

    receipt = await singletonDeployer.deploy(hyperProverTx.data, salt, {
      gasLimit: 1000000,
    })
    console.log('hyperProver deployed')

    hyperProverAddress = (
      await singletonDeployer.queryFilter(
        singletonDeployer.filters.Deployed,
        receipt.blockNumber,
      )
    )[0].args.addr

    console.log(`hyperProver deployed to: ${hyperProverAddress}`)
  }

  console.log('Waiting for 15 seconds for Bytecode to be on chain')
  await setTimeout(15000)

  try {
    await run('verify:verify', {
      address: inboxAddress,
      constructorArguments: [deployer.address, true, []],
    })
    console.log('inbox verified at:', inboxAddress)
  } catch (e) {
    console.log(`Error verifying inbox`, e)
  }

  try {
    // For verification, we need to use the same trustedProvers array that was used during deployment
    await run('verify:verify', {
      address: hyperProverAddress,
      constructorArguments: [
        deployNetwork.hyperlaneMailboxAddress,
        inboxAddress,
        [], // Use empty array for verification if no trusted provers were provided
      ],
    })
    console.log('hyperProver verified at:', hyperProverAddress)
  } catch (e) {
    console.log(`Error verifying hyperProver`, e)
  }

  console.log(`
  -----------------------------------------------
  IMPORTANT NEXT STEPS AFTER DEPLOYMENT:
  -----------------------------------------------
  1. Configure the Inbox with provers:
     - inbox.setProvers([hyperProverAddress])
  
  2. If deploying MetaProver, use this command:
     - Deploy: npx hardhat run scripts/deployMetaProver.ts --network <network>
     - Configure: inbox.setProvers([hyperProverAddress, metaProverAddress])
  
  3. For production systems, configure trusted provers with chain IDs:
     - hyperProver.addTrustedProvers([
         { chainId: 1, prover: "0x1234..." },
         { chainId: 10, prover: "0x5678..." }
       ])
  -----------------------------------------------
  `)
}

main().catch((error) => {
  console.error('Error during deployment:', error.message)
  process.exitCode = 1
  // Don't use process.exit() directly, set exitCode instead
})
