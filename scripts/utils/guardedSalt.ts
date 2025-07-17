import { getAddress, hexToBytes, bytesToHex } from 'viem'

/**
 * Default deployer address for guarded salt generation
 */
export const DEFAULT_DEPLOYER_ADDRESS =
  '0xB963326B9969f841361E6B6605d7304f40f6b414' as const

/**
 * Deployer address used for guarded salt generation
 * Can be overridden by DEPLOYER_ADDRESS environment variable
 */
export const DEPLOYER_ADDRESS = (() => {
  const address = process.env.DEPLOYER_ADDRESS || DEFAULT_DEPLOYER_ADDRESS
  if (!address) {
    throw new Error('DEPLOYER_ADDRESS must be set')
  }
  // Validate that it's a valid Ethereum address format
  if (!/^0x[a-fA-F0-9]{40}$/.test(address)) {
    throw new Error(
      `Invalid DEPLOYER_ADDRESS format: ${address}. Must be a valid Ethereum address.`,
    )
  }
  return address as `0x${string}`
})()

/**
 * Enum for the selection of a permissioned deploy protection
 */
export enum SenderBytes {
  MsgSender = 0,
  ZeroAddress = 1,
  Random = 2,
}

/**
 * Enum for the selection of a cross-chain redeploy protection
 */
export enum RedeployProtectionFlag {
  True = 0,
  False = 1,
  Unspecified = 2,
}

/**
 * Configuration for guarded salt generation
 */
export interface GuardedSaltConfig {
  /** The deployer address that will be allowed to deploy */
  deployer: `0x${string}`
  /** The base salt value */
  salt: `0x${string}`
  /** Whether to enable cross-chain redeploy protection */
  crossChainProtection?: boolean
  /** The chain ID for cross-chain protection */
  chainId?: number
}

/**
 * Creates a guarded salt that only allows the specified deployer to use for CREATE3 deployment
 * Based on CreateX's safeguarding mechanism
 *
 * @param config Configuration object for guarded salt generation
 * @returns The guarded salt that can only be used by the specified deployer
 * @throws Error if deployer address is not set or invalid
 */
export function createGuardedSalt(config: GuardedSaltConfig): `0x${string}` {
  const { deployer, salt, crossChainProtection = false, chainId } = config

  // Validate deployer address
  if (!deployer) {
    throw new Error('Deployer address is required for guarded salt generation')
  }

  const deployerAddress = getAddress(deployer)

  console.log('🔒 Creating guarded salt:')
  console.log('  Input salt:', salt)
  console.log('  Deployer:', deployerAddress)
  console.log('  Cross-chain protection:', crossChainProtection)
  if (chainId) console.log('  Chain ID:', chainId)

  // Create the permission-protected salt structure
  // Salt format: [deployer (20 bytes)][protection flag (1 byte)][random (11 bytes)]
  const saltBytes = hexToBytes(salt)

  // Take the last 11 bytes of the original salt as random data
  const randomBytes = saltBytes.slice(-11)

  // Create the structured salt according to CreateX protection format
  const deployerBytes = hexToBytes(deployerAddress)

  // Protection flag meanings:
  // 0x00: RedeployProtectionFlag.False - Only sender protection, no cross-chain protection
  // 0x01: RedeployProtectionFlag.True - Both sender and cross-chain protection enabled
  const protectionFlag = crossChainProtection
    ? new Uint8Array([0x01]) // Enable cross-chain redeploy protection
    : new Uint8Array([0x00]) // Disable cross-chain redeploy protection (sender protection only)

  // Combine: deployer (20 bytes) + protection flag (1 byte) + random (11 bytes)
  const structuredSalt = new Uint8Array(32)
  structuredSalt.set(deployerBytes, 0) // First 20 bytes: deployer address
  structuredSalt.set(protectionFlag, 20) // Byte 21: protection flag
  structuredSalt.set(randomBytes, 21) // Last 11 bytes: random data

  const structuredSaltHex = bytesToHex(structuredSalt) as `0x${string}`
  console.log('  Structured salt:', structuredSaltHex)

  // CRITICAL: Return the structured salt directly without hashing!
  // CreateX expects the deployer address to be literally in the first 20 bytes
  // of the salt for its protection mechanism to work. Hashing destroys this.
  const guardedSalt = structuredSaltHex

  console.log('  Output guarded salt:', guardedSalt)
  console.log('')

  return guardedSalt
}

/**
 * Convenience function to create a guarded salt for the configured deployer address
 * Uses DEPLOYER_ADDRESS constant (can be overridden by environment variable)
 * @throws Error if DEPLOYER_ADDRESS is not set or invalid
 */
export function createGuardedSaltForDeployer(
  salt: `0x${string}`,
  crossChainProtection: boolean = false,
  chainId?: number,
): `0x${string}` {
  if (!DEPLOYER_ADDRESS) {
    throw new Error(
      'DEPLOYER_ADDRESS is not set. Please set the DEPLOYER_ADDRESS environment variable or use the default.',
    )
  }

  return createGuardedSalt({
    deployer: DEPLOYER_ADDRESS,
    salt,
    crossChainProtection,
    chainId,
  })
}

/**
 * Parses a salt to understand its protection configuration
 * Replicates CreateX's _parseSalt function
 */
export function parseSalt(
  salt: `0x${string}`,
  msgSender: `0x${string}`,
): {
  senderBytes: SenderBytes
  redeployProtectionFlag: RedeployProtectionFlag
} {
  const saltBytes = hexToBytes(salt)
  const addressBytes = saltBytes.slice(0, 20)
  const protectionByte = saltBytes[20]

  const addressFromSalt = getAddress(bytesToHex(addressBytes))
  const msgSenderAddress = getAddress(msgSender)

  if (addressFromSalt === msgSenderAddress && protectionByte === 0x01) {
    return {
      senderBytes: SenderBytes.MsgSender,
      redeployProtectionFlag: RedeployProtectionFlag.True,
    }
  } else if (addressFromSalt === msgSenderAddress && protectionByte === 0x00) {
    return {
      senderBytes: SenderBytes.MsgSender,
      redeployProtectionFlag: RedeployProtectionFlag.False,
    }
  } else if (addressFromSalt === msgSenderAddress) {
    return {
      senderBytes: SenderBytes.MsgSender,
      redeployProtectionFlag: RedeployProtectionFlag.Unspecified,
    }
  } else if (
    addressFromSalt === '0x0000000000000000000000000000000000000000' &&
    protectionByte === 0x01
  ) {
    return {
      senderBytes: SenderBytes.ZeroAddress,
      redeployProtectionFlag: RedeployProtectionFlag.True,
    }
  } else if (
    addressFromSalt === '0x0000000000000000000000000000000000000000' &&
    protectionByte === 0x00
  ) {
    return {
      senderBytes: SenderBytes.ZeroAddress,
      redeployProtectionFlag: RedeployProtectionFlag.False,
    }
  } else if (addressFromSalt === '0x0000000000000000000000000000000000000000') {
    return {
      senderBytes: SenderBytes.ZeroAddress,
      redeployProtectionFlag: RedeployProtectionFlag.Unspecified,
    }
  } else {
    return {
      senderBytes: SenderBytes.Random,
      redeployProtectionFlag: RedeployProtectionFlag.False,
    }
  }
}

/**
 * Validates that a guarded salt can only be used by the specified deployer
 * This validates the protection mechanism by checking if the deployer address
 * matches the first 20 bytes of the salt (as CreateX expects)
 */
export function validateGuardedSalt(
  guardedSalt: `0x${string}`,
  originalSalt: `0x${string}`,
  expectedDeployer: `0x${string}`,
  chainId?: number,
): boolean {
  const expectedGuardedSalt = createGuardedSalt({
    deployer: expectedDeployer,
    salt: originalSalt,
    crossChainProtection: !!chainId,
    chainId,
  })

  return guardedSalt === expectedGuardedSalt
}

/**
 * Validates that a salt is properly protected by checking if it contains
 * the expected deployer address in the first 20 bytes (CreateX format)
 */
export function validateSaltProtection(
  salt: `0x${string}`,
  expectedDeployer: `0x${string}`,
): boolean {
  const saltBytes = hexToBytes(salt)
  const deployerBytes = hexToBytes(expectedDeployer)

  // Check if first 20 bytes match the expected deployer address
  for (let i = 0; i < 20; i++) {
    if (saltBytes[i] !== deployerBytes[i]) {
      return false
    }
  }

  return true
}

/**
 * Example usage and testing function
 */
export function exampleUsage() {
  const deployer = DEPLOYER_ADDRESS
  const baseSalt =
    '0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

  console.log('Creating guarded salts for deployer:', deployer)
  console.log('Base salt:', baseSalt)

  // Create guarded salt without cross-chain protection
  const guardedSalt1 = createGuardedSaltForDeployer(baseSalt, false)
  console.log('Guarded salt (no cross-chain protection):', guardedSalt1)

  // Create guarded salt with cross-chain protection
  const guardedSalt2 = createGuardedSaltForDeployer(baseSalt, true, 1)
  console.log(
    'Guarded salt (with cross-chain protection for chain 1):',
    guardedSalt2,
  )

  // Validate the guarded salt
  const isValid = validateGuardedSalt(guardedSalt1, baseSalt, deployer)
  console.log('Is guarded salt valid?', isValid)

  return {
    deployer,
    baseSalt,
    guardedSalt1,
    guardedSalt2,
    isValid,
  }
}
