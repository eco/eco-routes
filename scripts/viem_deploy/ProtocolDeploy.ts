import {
  encodeDeployData,
  Hex,
  zeroAddress,
  Chain,
  encodeAbiParameters,
  PrivateKeyAccount,
  RpcSchema,
  Transport,
  toBytes,
  keccak256,
} from 'viem'
import MainnetContracts, { ContractDeployConfigs } from './contracts/mainnet'
import { Create2Deployer, Create3Deployer } from './contracts/deployer'
import {
  DeployWalletClient,
  getClient,
  getConstructorArgs,
  getDeployAccount,
  getGitRandomSalt,
} from './utils'
import {
  createFile,
  addJsonAddress,
  jsonFilePath,
  saveDeploySalts,
  SaltsType,
  JsonConfig,
} from '../deploy/addresses'
import { DeployChains } from './chains'
import * as dotenv from 'dotenv'
import { storageProverSupported, waitForNonceUpdate, waitMs } from '../utils'
import { verifyContract } from './verify'
// eslint-disable-next-line node/no-missing-import
import PQueue from 'p-queue'
import { isEmpty } from 'lodash'
import { ViemDeployConfig } from './config'

dotenv.config()

/**
 * Deploy types options.
 */
export type DeployOpts = {
  pre?: boolean // if the contract is a pre contract, ie preprod/dev
  retry?: boolean // if the deploy fails, retry
  deployType?: 'create2' | 'create3' // the deploy type to use(defaults to create3)
}

// wait for 10 seconds before polling for nonce update
const NONCE_POLL_INTERVAL = 10000
type DeployWallletType = DeployWalletClient<
  Transport,
  Chain,
  PrivateKeyAccount,
  RpcSchema
>
/**
 * Deploys the eco protocol to all the chains passed with the salts provided.
 * After deploy it verify the contracts on etherscan.
 */
export class ProtocolDeploy {
  // The queue for verifying contracts on etherscan
  private queueVerify = new PQueue({ interval: 1000, intervalCap: 1 }) // theres a 5/second limit on etherscan
  // The queue for deploying contracts to chains
  private queueDeploy = new PQueue()
  // The chains to deploy the contracts to
  private deployChains: Chain[] = []
  // The salts to use for deploying the contracts, if emtpy it will generate random salts
  private salts?: SaltsType

  // The clients for the chains. Initialize once use multiple times
  private clients: {
    [key: string]: DeployWallletType
  } = {}

  // The account to deploy the contracts with, loaded from env process.env.DEPLOYER_PRIVATE_KEY
  private account: PrivateKeyAccount

  /**
   * Constructor that initializes the account and clients for the chains.
   * @param deployChains the chains to deploy the contracts to, defaults to {@link DeployChains}
   * @param salts
   */
  constructor(deployChains: Chain[] = DeployChains, salts?: SaltsType) {
    this.deployChains = deployChains
    this.account = getDeployAccount()
    for (const chain of deployChains) {
      const val = getClient(chain, this.account)
      this.clients[chain.id] = val
    }
    this.salts = salts
    createFile(jsonFilePath)
  }

  /**
   * Deploy the full network to all the chains passed in the constructor.
   * @param concurrent if the chain deploys should be done concurrently or not
   */
  async deployFullNetwork(concurrent: boolean = false) {
    const { salt, saltPre } = !isEmpty(this.salts)
      ? this.salts
      : { salt: getGitRandomSalt(), saltPre: getGitRandomSalt() }
    saveDeploySalts({ salt, saltPre })
    console.log('Using Salts :', salt, saltPre)
    for (const chain of this.deployChains) {
      if (concurrent) {
        this.queueDeploy.add(async () => {
          await this.deployViemContracts(chain, salt)
          await this.deployViemContracts(chain, saltPre, {
            pre: true,
            retry: true,
          })
        })
      } else {
        await this.deployViemContracts(chain, salt)
        await this.deployViemContracts(chain, saltPre, {
          pre: true,
          retry: true,
        })
      }
    }

    if (concurrent) {
      // wait for queue to finish
      await this.queueDeploy.onIdle()
    }
    // wait for verification queue to finish
    await this.queueVerify.onIdle()
  }

  /**
   * Deploys the network to a chain with a given salt.
   *
   * @param chain the chain to deploy on
   * @param salt the origin salt to use
   * @param opts deploy options
   */
  async deployViemContracts(chain: Chain, salt: Hex, opts?: DeployOpts) {
    console.log('Deploying contracts with the account:', this.account.address)

    console.log('Deploying with base salt : ' + JSON.stringify(salt))
    try {
      // await this.deployProver(chain, salt, opts)
      await this.deployIntentSource(chain, salt, { pre: opts?.pre, deployType: 'create3', retry: true, })
      await this.deployInbox(chain, salt, true, { pre: opts?.pre, deployType: 'create3', retry: true, })
    } catch (e) {
      console.error(`Failed to deploy contracts on ${chain.name}:`, e)
      console.error('Moving onto next chain...')
    }
  }

  /**
   * Deploys the prover contract.
   *
   * @param chain the chain to deploy on
   * @param salt the origin salt to use
   * @param opts deploy options
   */
  // async deployProver(chain: Chain, salt: Hex, opts?: DeployOpts) {
  //   await this.deployAndVerifyContract(
  //     chain,
  //     salt,
  //     getConstructorArgs(chain, 'Prover'),
  //     opts,
  //   )
  // }

  /**
   * Deploys the intent source contract.
   *
   * @param chain the chain to deploy on
   * @param salt the origin salt to use
   * @param opts deploy options
   */
  async deployIntentSource(chain: Chain, salt: Hex, opts?: DeployOpts) {
    const params = {
      ...getConstructorArgs(chain, 'IntentSource'),
      args: [],
    }
    await this.deployAndVerifyContract(chain, salt, params, opts)
  }

  /**
   * Deploys the inbox contract, and optionally the hyper prover contract.
   *
   * @param chain the chain to deploy on
   * @param salt the origin salt to use
   * @param deployHyper if the hyper prover should be deployed
   * @param opts deploy options
   */
  async deployInbox(
    chain: Chain,
    salt: Hex,
    deployHyper: boolean,
    opts: DeployOpts = { deployType: 'create3', retry: true, pre: false },
  ) {
    const config = ViemDeployConfig[chain.id]
    const ownerAndSolver = this.account.address

    const params = {
      ...getConstructorArgs(chain, 'Inbox'),
      args: [ownerAndSolver, true, [ownerAndSolver]],
    }
    const inboxAddress = await this.deployAndVerifyContract(
      chain,
      salt,
      params,
      opts,
    )

    try {
      const client = this.clients[chain.id]
      const { request } = await client.simulateContract({
        address: inboxAddress,
        abi: MainnetContracts.Inbox.abi,
        functionName: 'setMailbox',
        args: [config.hyperlaneMailboxAddress],
      })
      await waitForNonceUpdate(
        client as any,
        this.account.address,
        NONCE_POLL_INTERVAL,
        async () => {
          const hash = await client.writeContract(request)
          await client.waitForTransactionReceipt({ hash })
        },
      )

      console.log(
        `Chain: ${chain.name}, Inbox ${inboxAddress} setMailbox to: ${config.hyperlaneMailboxAddress}`,
      )
    } catch (error) {
      console.error(
        `Chain: ${chain.name}, Failed to set hyperlane mailbox address ${config.hyperlaneMailboxAddress} on inbox contract ${inboxAddress}:`,
        error,
      )
      if (opts.retry) {
        opts.retry = false
        console.log(
          `Retrying setting hyperlane mailbox address on inbox contract ${inboxAddress}...`,
        )
        // wait for 15 seconds before retrying
        await new Promise((resolve) => setTimeout(resolve, 15000))
        await this.deployInbox(chain, salt, deployHyper, opts)
      }
      return
    }

    if (deployHyper) {
      await this.deployHyperProver(chain, salt, inboxAddress, opts)
    }
  }

  /**
   * Deploys the hyper prover contract.
   *
   * @param chain the chain to deploy on
   * @param salt the origin salt to use
   * @param inboxAddress the inbox address
   * @param opts deploy options
   */
  async deployHyperProver(
    chain: Chain,
    salt: Hex,
    inboxAddress: Hex,
    opts?: DeployOpts,
  ) {
    const config = ViemDeployConfig[chain.id]
    const params = {
      ...getConstructorArgs(chain, 'HyperProver'),
      args: [config.hyperlaneMailboxAddress, inboxAddress],
    }
    opts = { ...opts, deployType: 'create3' }
    await this.deployAndVerifyContract(chain, salt, params, opts)
  }

  /**
   * Deploys a contract and verifies it on etherscan.
   *
   * @param chain the chain to deploy on
   * @param salt the origin salt to use
   * @param parameters the contract parameters, abi, constructor args etc
   * @param opts deploy options
   */
  async deployAndVerifyContract(
    chain: Chain,
    salt: Hex,
    parameters: ContractDeployConfigs,
    opts: DeployOpts = { deployType: 'create3', retry: true, pre: false },
  ): Promise<Hex> {
    if (!storageProverSupported(chain.id, parameters.name)) {
      console.log(
        `Unsupported network ${chain.name} detected, skipping storage Prover deployment`,
      )
      return zeroAddress
    }
    // if create3, transform the salt
    if (opts.deployType === 'create3') {
      salt = this.transformSalt(salt, parameters.name)
    }
    const { name } = parameters
    const client = this.clients[chain.id]

    console.log(`Deploying ${name}...`)

    try {
      const encodedDeployData = encodeDeployData(parameters)
      let args: any = {}
      if (parameters.args) {
        const description = parameters.abi.find(
          (x: any) => 'type' in x && x.type === 'constructor',
        )
        args = encodeAbiParameters(description.inputs, parameters.args).slice(2) // chop the 0x off
      }
      console.log('salt is', salt)

      const deployerContract = this.getDepoyerContract(opts)

      const hasDeployedAddress = await this.getDeployedAddress(
        client,
        deployerContract,
        encodedDeployData,
        salt,
      )
      let deployedAddress: Hex
      if (!hasDeployedAddress) {
        const { request, result } = await client.simulateContract({
          address: deployerContract.address,
          abi: deployerContract.abi,
          functionName: 'deploy',
          args: [encodedDeployData, salt],
        })

        await waitForNonceUpdate(
          client as any,
          this.account.address,
          NONCE_POLL_INTERVAL,
          async () => {
            const hash = await client.writeContract(request)
            // wait so that the nonces dont collide
            await client.waitForTransactionReceipt({ hash })
          },
        )
        deployedAddress = result
      } else {
        console.log(
          `Contract has already been deployed to chain ${chain.name} at address ${hasDeployedAddress}. Skipping deploy`,
        )
        deployedAddress = hasDeployedAddress
      }

      console.log(
        `Chain: ${chain.name}, ${name} deployed at: ${deployedAddress}`,
      )

      const jsonConfig: JsonConfig = {
        chainId: chain.id,
        pre: opts.pre || false,
      }
      addJsonAddress(jsonConfig, `${name}`, deployedAddress)
      console.log(
        `Chain: ${chain.name}, ${name} address updated in addresses.json`,
      )
      // Verify the contract on Etherscan
      if (!hasDeployedAddress) {
        console.log(`Verifying ${name} on Etherscan...`)
        this.queueVerify.add(async () =>
          verifyContract({
            chainId: chain.id,
            codeformat: 'solidity-standard-json-input',
            constructorArguements: args,
            contractname: name,
            contractaddress: deployedAddress,
            contractFilePath: `${parameters.path}/${name}.sol`,
          }),
        )
      } else {
        console.log(
          `Skipping verification of ${name} on Etherscan since contract was previously deployed...`,
        )
      }

      return deployedAddress
    } catch (error) {
      console.error(
        `Chain: ${chain.name}, Failed to deploy or verify ${name}:`,
        error,
      )
      if (opts.retry) {
        opts.retry = false
        console.log(`Retrying ${name} deployment...`)
        // wait for 15 seconds before retrying
        await waitMs(15000)
        return await this.deployAndVerifyContract(chain, salt, parameters, opts)
      } else {
        throw new Error(
          `Contract address is null, might not have deployed. Chain: ${chain.name}, Failed to deploy or verify ${name}: ${error}`,
        )
      }
    }
  }

  async getDeployedAddress(
    client: DeployWallletType,
    deployerContract: any,
    encodedDeployData: Hex,
    salt: Hex,
  ) {
    const { result: deployedAddress } = await client.simulateContract({
      address: deployerContract.address,
      abi: deployerContract.abi,
      functionName: 'deployedAddress',
      args: [encodedDeployData, this.account.address, salt],
    })
    const bytecode = await client.getCode({
      address: deployedAddress as unknown as Hex,
    })

    // If bytecode is empty, there's no contract deployed
    const contractDeployed = !!bytecode && bytecode !== '0x'
    return contractDeployed ? (deployedAddress as unknown as Hex) : null
  }

  /**
   * Transforms a given salt with a contract name and then keccaks it.
   * Generates a deterministic salt per contract.
   *
   * @param salt the origin salt
   * @param contractName the name of the contract
   * @returns
   */
  transformSalt(salt: Hex, contractName: string): Hex {
    const transformedSalt = keccak256(toBytes(salt + contractName))
    console.log(
      `Transformed salt ${salt} for ${contractName}: ${transformedSalt}`,
    )
    return transformedSalt
  }

  /**
   * Gets the deployer contract based on the deploy opts.
   *
   * @param opts the deploy opts
   * @returns
   */
  getDepoyerContract(opts: DeployOpts) {
    switch (opts.deployType) {
      case 'create3':
        return Create3Deployer
      case 'create2':
      default:
        return Create2Deployer
    }
  }
}
