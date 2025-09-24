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
): Promise<{ rootSalt: Hex; stagingRootSalt: Hex }> {
  // Extract version components
  const versionBase = getBaseVersion(version, logger)
  const optionalSalt = process.env[ENV_VARS.SALT_OPTIONAL] || ''
  // major/minor version - calculate fresh salt
  logger.log(
    `major/minor version (${versionBase}) with optional salt (${optionalSalt}), calculating salt`,
  )
  const sum = versionBase + optionalSalt
  const rootSalt = (process.env.ROOT_SALT || keccak256(toHex(sum))) as Hex
  const stagingRootSalt = (
    process.env.ROOT_SALT // if root is overridden, use the original prod for staging
      ? keccak256(toHex(sum))
      : keccak256(toHex(`${sum}-staging`))
  ) as Hex

  logger.log(`Using salt for production: ${rootSalt}`)
  logger.log(`Using salt for staging: ${stagingRootSalt}`)
  // const { rootSalt, stagingRootSalt } = {
  //   rootSalt:
  //     '0x000000000000000000000000000000000000000000000001000000A7E199AFCA' as Hex,
  //   stagingRootSalt:
  //     '0x0000000000000000000000000000000000000000000000010000004EbDe90aBF' as Hex,
  // }
  return { rootSalt, stagingRootSalt }
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
