import { getAddress, Hex } from 'viem'
import { ENV_VARS } from '../semantic-release/constants'
import { privateKeyToAccount } from 'viem/accounts'
import dotenv from 'dotenv'
dotenv.config()

/**
 *
 * @returns The deployer's address derived from the private key in the environment variables.
 */
export function getDeployerAddress(): Hex {
  return getAddress(
    privateKeyToAccount(process.env[ENV_VARS.PRIVATE_KEY] as Hex).address,
  )
}
