import { getAddress, Hex } from 'viem'
import { ENV_VARS } from '../semantic-release/constants'
import { privateKeyToAccount } from 'viem/accounts'
import dotenv from 'dotenv'
dotenv.config()

export function getDeployerAddress(): Hex {
  return getAddress(
    privateKeyToAccount(process.env[ENV_VARS.PRIVATE_KEY] as Hex).address,
  )
}
