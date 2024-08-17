import { ethers, run, network } from 'hardhat'
import { IntentSource, Inbox } from '../../typechain-types'
import { setTimeout } from 'timers/promises'
// import { getAddress } from 'ethers'
// import c from '../config/testnet/config'
// import networks from '../config/testnet/config';
import { networks, actors } from '../../config/testnet/config'

const networkName = network.name
console.log('Deploying to Network: ', network.name)
const baseSepoliaChainConfiguration = {
  chainId: networks.baseSepolia.chainId, // chainId
  chainConfiguration: {
    provingMechanism: networks.baseSepolia.proving.mechanism, // provingMechanism
    settlementChainId: networks.baseSepolia.proving.settlementChain.id, // settlementChainId
    settlementContract: networks.baseSepolia.proving.settlementChain.contract, // settlementContract e.g DisputGameFactory or L2OutputOracle.
    blockhashOracle: networks.baseSepolia.proving.l1BlockAddress, // blockhashOracle
    outputRootVersionNumber:
      networks.baseSepolia.proving.outputRootVersionNumber, // outputRootVersionNumber
  },
}

const optimismSepoliaChainConfiguration = {
  chainId: networks.optimismSepolia.chainId, // chainId
  chainConfiguration: {
    provingMechanism: networks.optimismSepolia.proving.mechanism, // provingMechanism
    settlementChainId: networks.optimismSepolia.proving.settlementChain.id, // settlementChainId
    settlementContract:
      networks.optimismSepolia.proving.settlementChain.contract, // settlementContract e.g DisputGameFactory or L2OutputOracle.
    blockhashOracle: networks.optimismSepolia.proving.l1BlockAddress, // blockhashOracle
    outputRootVersionNumber:
      networks.optimismSepolia.proving.outputRootVersionNumber, // outputRootVersionNumber
  },
}

const ecoTestNetChainConfiguration = {
  chainId: networks.ecoTestNet.chainId, // chainId
  chainConfiguration: {
    provingMechanism: networks.ecoTestNet.proving.mechanism, // provingMechanism
    settlementChainId: networks.ecoTestNet.proving.settlementChain.id, // settlementChainId
    settlementContract: networks.ecoTestNet.proving.settlementChain.contract, // settlementContract e.g DisputGameFactory or L2OutputOracle.
    blockhashOracle: networks.ecoTestNet.proving.l1BlockAddress, // blockhashOracle
    outputRootVersionNumber:
      networks.ecoTestNet.proving.outputRootVersionNumber, // outputRootVersionNumber
  },
}
let counter: number = 0
let minimumDuration: number = 0
switch (networkName) {
  case 'baseSepolia':
    counter = networks.baseSepolia.intentSource.counter
    minimumDuration = networks.baseSepolia.intentSource.minimumDuration
    break
  case 'optimismSepolia':
    counter = networks.optimismSepolia.intentSource.counter
    minimumDuration = networks.optimismSepolia.intentSource.counter
    break
  case 'ecoTestNet':
    counter = networks.ecoTestNet.intentSource.counter
    minimumDuration = networks.ecoTestNet.intentSource.counter
    break
  default:
    counter = 0
    minimumDuration = 0
    break
}
console.log('Counter: ', counter)

console.log('Deploying to Network: ', network.name)

async function main() {
  const [deployer] = await ethers.getSigners()
  console.log('Deploying contracts with the account:', deployer.address)
  const proverFactory = await ethers.getContractFactory('Prover')
  const prover = await proverFactory.deploy([
    baseSepoliaChainConfiguration,
    optimismSepoliaChainConfiguration,
    ecoTestNetChainConfiguration,
  ])
  console.log('prover implementation deployed to: ', await prover.getAddress())

  // adding a try catch as if the contract has previously been deployed will get a
  // verification error when deploying the same bytecode to a new address
  try {
    if (network.name !== 'hardhat') {
      console.log('Waiting for 30 seconds for Bytecode to be on chain')
      await setTimeout(30000)
      await run('verify:verify', {
        address: await prover.getAddress(),
        // constructorArguments: [l1BlockAddressSepolia, deployer.address],
        constructorArguments: [
          [
            baseSepoliaChainConfiguration,
            optimismSepoliaChainConfiguration,
            ecoTestNetChainConfiguration,
          ],
        ],
      })
      console.log('prover  verified at:', await prover.getAddress())
    }
  } catch (e) {
    console.log(`Error verifying prover`, e)
  }

  const intentSourceFactory = await ethers.getContractFactory('IntentSource')
  const intentSource: IntentSource = await intentSourceFactory.deploy(
    minimumDuration,
    counter,
  )
  console.log('intentSource deployed to:', await intentSource.getAddress())

  // adding a try catch as if the contract has previously been deployed will get a
  // verification error when deploying the same bytecode to a new address
  try {
    if (network.name !== 'hardhat') {
      console.log('Waiting for 30 seconds for Bytecode to be on chain')
      await setTimeout(30000)
      await run('verify:verify', {
        address: await intentSource.getAddress(),
        constructorArguments: [
          await prover.getAddress(),
          minimumDuration,
          counter,
        ],
      })
    }
    console.log('intentSource verified at:', await intentSource.getAddress())
  } catch (e) {
    console.log(`Error verifying intentSource`, e)
  }

  const inboxFactory = await ethers.getContractFactory('Inbox')

  const inbox: Inbox = await inboxFactory.deploy(deployer.address, false, [
    actors.solver,
  ])
  console.log('Inbox deployed to:', await inbox.getAddress())

  // adding a try catch as if the contract has previously been deployed will get a
  // verification error when deploying the same bytecode to a new address
  try {
    if (network.name !== 'hardhat') {
      console.log('Waiting for 30 seconds for Bytecode to be on chain')
      await setTimeout(30000)
      await run('verify:verify', {
        address: await inbox.getAddress(),
        constructorArguments: [deployer.address, false, [actors.solver]],
      })
    }
    console.log('Inbox verified at:', await inbox.getAddress())
  } catch (e) {
    console.log(`Error verifying inbox`, e)
  }
}

main().catch((error) => {
  console.error(error)
  process.exitCode = 1
})
