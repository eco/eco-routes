import { Hex, keccak256, toHex } from 'viem'
import { Logger } from '../semantic-release/helpers'
import { ENV_VARS } from '../semantic-release/constants'

/**
 * Determine salts for deployment based on version
 * @param version The full semantic version string (e.g. "1.2.3")
 * @param logger Logger interface for output
 * @returns Object containing production and pre-production salts
 */
export async function determineSalts(
  version: string,
  logger: Logger,
): Promise<{ rootSalt: Hex; preprodRootSalt: Hex }> {
  // Extract version components
  const versionBase = getBaseVersion(version, logger)
  const optionalSalt = process.env[ENV_VARS.SALT_OPTIONAL] || ''
  // major/minor version - calculate fresh salt
  logger.log(
    `major/minor version (${versionBase}) with optional salt (${optionalSalt}), calculating salt`,
  )
  const rootSalt = keccak256(toHex(versionBase + optionalSalt))
  const preprodRootSalt = keccak256(toHex(`${versionBase}-preprod`))

  logger.log(`Using salt for production: ${rootSalt}`)
  logger.log(`Using salt for pre-production: ${preprodRootSalt}`)

  return { rootSalt, preprodRootSalt }
}

/**
 * @description This function extracts the major and minor version from a semantic version string.
 * It splits the version string by the dot (.) character and joins the first two parts (major and minor) back together.
 *
 * @param version the semver version string
 * @param logger the logger instance
 * @returns
 */
export function getBaseVersion(version: string, logger: Logger): string {
  // Extract major and minor version
  const versionBase = version.split('.').slice(0, 2).join('.')
  logger.log(`Extracted base version: ${versionBase}`)
  return versionBase
}
