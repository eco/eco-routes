import { ethers } from 'hardhat'
import { addJsonAddress } from './deploy/addresses'
import { ContractTransactionResponse, Signer } from 'ethers'
import { Deployer, Inbox, Prover } from '../typechain-types'
import { Address, Hex, zeroAddress } from 'viem'
import {
  isZeroAddress,
  storageProverSupported,
  retryFunction,
  verifyContract,
} from './utils'
import { getGitHash } from './publish/gitUtils'
export const ALCHEMY_API_KEY = process.env.ALCHEMY_API_KEY || ''

const singletonFactoryAddress = '0xce0042B868300000d44A59004Da54A005ffdcf9f'

export type DeployNetwork = {
  gasLimit: number
  intentSource: {
    counter: number
  }
  hyperlaneMailboxAddress: Hex
  metalayerRouterAddress: Hex
  network: string
  pre: boolean // whether this is a pre deployment to a network, think preproduction
  chainId: number
  chainConfiguration: {
    provingMechanism: number
    settlementChainId: number
    settlementContract: Hex
    blockhashOracle: Hex
    outputRootVersionNumber: number
    finalityDelaySeconds: number
  }
  [key: string]: any
}

export type DeployNetworkConfig = Pick<
  DeployNetwork,
  'chainId' | 'chainConfiguration'
>
export type DeployDisputeNetworkConfig = Omit<
  DeployNetwork,
  'pre' | 'intentSource' | 'hyperlaneMailboxAddress' | 'gasLimit'
>
export type ProtocolDeploy = {
  proverAddress: Hex
  intentSourceAddress: Hex
  inboxAddress: Hex
  hyperProverAddress: Hex
  metalayerProverAddress: Hex
  initialSalt: string
}

export function getEmptyProtocolDeploy(): ProtocolDeploy {
  return {
    proverAddress: zeroAddress,
    intentSourceAddress: zeroAddress,
    inboxAddress: zeroAddress,
    hyperProverAddress: zeroAddress,
    metalayerProverAddress: zeroAddress,
    initialSalt: getGitHash(), // + Math.random().toString(), // randomize the salt for development as singletonDeployer.deploy(..) will fail if salt is already used
  }
}
export type DeployProtocolOptions = {
  isSolvingPublic: boolean
  deployPre?: boolean
}

export async function deployProtocol(
  protocolDeploy: ProtocolDeploy,
  deployNetwork: DeployNetwork,
  solver: Hex,
  proverConfig: any,
  options: DeployProtocolOptions = { isSolvingPublic: true },
) {
  const networkName = deployNetwork.network
  const salt = ethers.keccak256(
    ethers.toUtf8Bytes(protocolDeploy.initialSalt + deployNetwork.pre || ''),
  )

  const [deployer] = await ethers.getSigners()
  console.log('Deploying contracts with the account:', deployer.address)
  if (process.env.DEPLOY_CI === 'true') {
    console.log('Deploying for CI')
  }

  const singletonDeployer = (await ethers.getContractAt(
    'Deployer',
    '0xce0042B868300000d44A59004Da54A005ffdcf9f',
  )) as any as Deployer

  console.log('gasLimit:', deployNetwork.gasLimit)
  const pre = deployNetwork.pre ? ' Pre' : ''
  console.log(`***************************************************`)
  console.log(`** Deploying contracts to ${networkName + pre} network **`)
  console.log(`***************************************************`)

  // Deploys the storage prover
  // if (isZeroAddress(protocolDeploy.proverAddress)) {
  //   await deployProver(salt, deployNetwork, singletonDeployer, proverConfig)
  // }

  if (isZeroAddress(protocolDeploy.intentSourceAddress)) {
    protocolDeploy.intentSourceAddress = (await deployIntentSource(
      deployNetwork,
      salt,
      singletonDeployer,
    )) as Hex
  }

  if (isZeroAddress(protocolDeploy.inboxAddress)) {
    protocolDeploy.inboxAddress = (await deployInbox(
      deployNetwork,
      deployer,
      options.isSolvingPublic,
      [solver],
      salt,
      singletonDeployer,
    )) as Hex
  }

  if (
    isZeroAddress(protocolDeploy.hyperProverAddress) &&
    !isZeroAddress(protocolDeploy.inboxAddress)
  ) {
    protocolDeploy.hyperProverAddress = (await deployHyperProver(
      deployNetwork,
      protocolDeploy.inboxAddress,
      salt,
      singletonDeployer,
    )) as Hex
  }

  if (
    isZeroAddress(protocolDeploy.metalayerProverAddress) &&
    !isZeroAddress(protocolDeploy.inboxAddress)
  ) {
    protocolDeploy.metalayerProverAddress = (await deployHyperProver(
      deployNetwork,
      protocolDeploy.inboxAddress,
      salt,
      singletonDeployer,
    )) as Hex
  }

  if (
    isZeroAddress(protocolDeploy.metalayerProverAddress) &&
    !isZeroAddress(protocolDeploy.inboxAddress)
  ) {
    protocolDeploy.metalayerProverAddress = (await deployMetalayerProver(
      deployNetwork,
      protocolDeploy.inboxAddress,
      salt,
      singletonDeployer,
    )) as Hex
  }

  // deploy preproduction contracts
  if (options.deployPre) {
    deployNetwork.pre = true
    await deployProtocol(
      getEmptyProtocolDeploy(),
      deployNetwork,
      solver,
      proverConfig,
    )
  }
}

export async function deployProver(
  deploySalt: string,
  deployNetwork: DeployNetwork,
  singletonDeployer: Deployer,
  deployArgs: Prover.ChainConfigurationConstructorStruct[],
) {
  if (!storageProverSupported(deployNetwork.chainId, "Proverß")) {
    console.log(
      `Unsupported network ${deployNetwork.network} detected, skipping storage Prover deployment`,
    )
    return
  }
  const contractName = 'Prover'
  const proverFactory = await ethers.getContractFactory(contractName)
  const proverTx = await proverFactory.getDeployTransaction(deployArgs)
  await retryFunction(async () => {
    return await singletonDeployer.deploy(proverTx.data, deploySalt, {
      gasLimit: deployNetwork.gasLimit,
    })
  }, ethers.provider)
  // wait to verify contract
  const proverAddress = ethers.getCreate2Address(
    singletonFactoryAddress,
    deploySalt,
    ethers.keccak256(proverTx.data),
  ) as Hex

  console.log(`${contractName} implementation deployed to: `, proverAddress)
  addJsonAddress(deployNetwork, `${contractName}`, proverAddress)
  verifyContract(ethers.provider, contractName, proverAddress, [deployArgs])
  return proverAddress
}

export async function deployIntentSource(
  deployNetwork: DeployNetwork,
  deploySalt: string,
  singletonDeployer: Deployer,
) {
  const contractName = 'IntentSource'
  const args = [deployNetwork.intentSource.counter]

  const intentSourceFactory = await ethers.getContractFactory(contractName)
  const intentSourceTx = await intentSourceFactory.getDeployTransaction(args[0])

  const deployTx = await singletonDeployer.deploy(
    intentSourceTx.data,
    deploySalt,
    { gasLimit: deployNetwork.gasLimit },
  )

  const intentSourceAddress = ethers.getCreate2Address(
    singletonFactoryAddress,
    deploySalt,
    ethers.keccak256(intentSourceTx.data),
  ) as Hex

  console.log(`${contractName} deployed to:`, intentSourceAddress)
  addJsonAddress(deployNetwork, `${contractName}`, intentSourceAddress)
  verifyContract(ethers.provider, contractName, intentSourceAddress, args)
  return intentSourceAddress
}

export async function deployInbox(
  deployNetwork: DeployNetwork,
  inboxOwnerSigner: Signer,
  isSolvingPublic: boolean,
  solvers: Hex[],
  deploySalt: string,
  singletonDeployer: Deployer,
) {
  const contractName = 'Inbox'
  const inboxFactory = await ethers.getContractFactory(contractName)
  const args = [await inboxOwnerSigner.getAddress(), isSolvingPublic, solvers]
  // on testnet inboxOwner is the deployer, just to make things easier
  const inboxTx = (await retryFunction(async () => {
    return await inboxFactory.getDeployTransaction(
      args[0] as Address,
      args[1] as boolean,
      args[2] as any,
    )
  }, ethers.provider)) as unknown as ContractTransactionResponse

  await retryFunction(async () => {
    return await singletonDeployer.deploy(inboxTx.data, deploySalt, {
      gasLimit: deployNetwork.gasLimit,
    })
  }, ethers.provider)
  // wait to verify contract
  const inboxAddress = ethers.getCreate2Address(
    singletonFactoryAddress,
    deploySalt,
    ethers.keccak256(inboxTx.data),
  ) as Hex

  // on testnet inboxOwner is the deployer, just to make things easier
  const inbox: Inbox = (await retryFunction(async () => {
    return await ethers.getContractAt(
      contractName,
      inboxAddress,
      inboxOwnerSigner,
    )
  }, ethers.provider)) as any as Inbox

  await retryFunction(async () => {
    await inbox
      .connect(inboxOwnerSigner)
      .setMailbox(deployNetwork.hyperlaneMailboxAddress, {
        gasLimit: deployNetwork.gasLimit,
      })
  }, ethers.provider)

  await retryFunction(async () => {
    await inbox
      .connect(inboxOwnerSigner)
      .setRouter(deployNetwork.metalayerRouterAddress, {
        gasLimit: deployNetwork.gasLimit,
      })
  }, ethers.provider)

  console.log(`${contractName} implementation deployed to: `, inboxAddress)
  addJsonAddress(deployNetwork, `${contractName}`, inboxAddress)
  verifyContract(ethers.provider, contractName, inboxAddress, args)
  return inboxAddress
}

export async function deployHyperProver(
  deployNetwork: DeployNetwork,
  inboxAddress: Hex,
  deploySalt: string,
  singletonDeployer: Deployer,
) {
  const contractName = 'HyperProver'
  const hyperProverFactory = await ethers.getContractFactory(contractName)
  const args = [deployNetwork.hyperlaneMailboxAddress, inboxAddress]
  const hyperProverTx = (await retryFunction(async () => {
    return await hyperProverFactory.getDeployTransaction(args[0], args[1])
  }, ethers.provider)) as any as ContractTransactionResponse

  await retryFunction(async () => {
    return await singletonDeployer.deploy(hyperProverTx.data, deploySalt, {
      gasLimit: deployNetwork.gasLimit,
    })
  }, ethers.provider)
  // wait to verify contract
  const hyperProverAddress = ethers.getCreate2Address(
    singletonFactoryAddress,
    deploySalt,
    ethers.keccak256(hyperProverTx.data),
  ) as Hex

  console.log(`${contractName} deployed to: ${hyperProverAddress}`)
  addJsonAddress(deployNetwork, `${contractName}`, hyperProverAddress)
  verifyContract(ethers.provider, contractName, hyperProverAddress, args)
  return hyperProverAddress
}

export async function deployMetalayerProver(
  deployNetwork: DeployNetwork,
  inboxAddress: Hex,
  deploySalt: string,
  singletonDeployer: Deployer,
) {
  const contractName = 'MetalayerProver'
  const metalayerProverFactory = await ethers.getContractFactory(contractName)
  const args = [deployNetwork.metalayerRouterAddress, inboxAddress]
  const metalayerProverTx = (await retryFunction(async () => {
    return await metalayerProverFactory.getDeployTransaction(
      args[0] as Address,
      args[1] as Address,
    )
  }, ethers.provider)) as unknown as ContractTransactionResponse

  await retryFunction(async () => {
    return await singletonDeployer.deploy(metalayerProverTx.data, deploySalt, {
      gasLimit: deployNetwork.gasLimit,
    })
  }, ethers.provider)

  const metalayerProverAddress = ethers.getCreate2Address(
    singletonFactoryAddress,
    deploySalt,
    ethers.keccak256(metalayerProverTx.data),
  ) as Hex

  console.log(`${contractName} deployed to:`, metalayerProverAddress)
  addJsonAddress(deployNetwork, `${contractName}`, metalayerProverAddress)
  verifyContract(ethers.provider, contractName, metalayerProverAddress, args)
  return metalayerProverAddress
}
