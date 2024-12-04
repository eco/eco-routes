import {
  Chain,
  createWalletClient,
  Hex,
  http,
  publicActions,
  sha256,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { getGitHash } from '../publish/gitUtils'
import SepoliaContracts from './contracts/sepolia'
import MainnetContracts, { ContractNames } from './contracts/mainnet'

export function getDeployAccount() {
  // Load environment variables
  const DEPLOYER_PRIVATE_KEY: Hex =
    (process.env.DEPLOYER_PRIVATE_KEY as Hex) || '0x'
  return privateKeyToAccount(DEPLOYER_PRIVATE_KEY)
}

export function getGitRandomSalt() {
  return sha256(`0x${getGitHash() + Math.random().toString()}`) // Random salt
}

export function getClient(chain: Chain) {
  const client = createWalletClient({
    transport: http(getUrl(chain)),
    chain,
    account: getDeployAccount(),
  })
  return client.extend(publicActions)
}

function getUrl(chain: Chain) {
  return getAchemyRPCUrl(chain) || chain.rpcUrls.default.http[0]
}

function getAchemyRPCUrl(chain: Chain): string | undefined {
  const apiKey = process.env.ALCHEMY_API_KEY
  if (!chain.rpcUrls.alchemy) {
    return undefined
  }
  return chain.rpcUrls.alchemy.http[0] + '/' + apiKey
}

export function getConstructorArgs(chain: Chain, contract: ContractNames) {
  return chain.testnet ? SepoliaContracts[contract] : MainnetContracts[contract]
}
