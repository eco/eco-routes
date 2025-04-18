import { keccak256, toHex } from 'viem'
import { Logger } from '../semantic-release/helpers'

/**
 * Determine salts for deployment based on version
 * @param version The full semantic version string (e.g. "1.2.3")
 * @param logger Logger interface for output
 * @returns Object containing production and pre-production salts
 */
export async function determineSalts(
  version: string,
  logger: Logger,
): Promise<{ rootSalt: string; preprodRootSalt: string }> {
  // Extract version components
  const [major, minor] = version.split('.')
  const versionBase = `${major}.${minor}`

  // major/minor version - calculate fresh salt
  logger.log(`major/minor version (${versionBase}), calculating salt`)
  const rootSalt = keccak256(toHex(versionBase))
  const preprodRootSalt = keccak256(toHex(`${versionBase}-preprod`))

  logger.log(`Using salt for production: ${rootSalt}`)
  logger.log(`Using salt for pre-production: ${preprodRootSalt}`)

  return { rootSalt, preprodRootSalt }
}
