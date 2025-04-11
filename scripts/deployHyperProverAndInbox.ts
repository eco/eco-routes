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
      gaslimit: 1000000,
    })
    console.log('inbox deployed')

    inboxAddress = (
      await singletonDeployer.queryFilter(
        singletonDeployer.filters.Deployed,
        receipt.blockNumber,
      )
    )[0].args.addr

    console.log(`inbox deployed to: ${inboxAddress}`)

    const inbox = await ethers.getContractAt('Inbox', inboxAddress)

    receipt = await inbox.setMailbox(deployNetwork.hyperlaneMailboxAddress)
    await receipt.wait()

    console.log(`Mailbox set to ${deployNetwork.hyperlaneMailboxAddress}`)
  }

  if (hyperProverAddress === '' && inboxAddress !== '') {
    const hyperProverFactory = await ethers.getContractFactory('HyperProver')

    const hyperProverTx = await hyperProverFactory.getDeployTransaction(
      deployNetwork.hyperlaneMailboxAddress,
      inboxAddress,
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
    await run('verify:verify', {
      address: hyperProverAddress,
      constructorArguments: [
        deployNetwork.hyperlaneMailboxAddress,
        inboxAddress,
      ],
    })
    console.log('hyperProver verified at:', hyperProverAddress)
  } catch (e) {
    console.log(`Error verifying hyperProver`, e)
  }
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
