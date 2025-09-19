/**
 * @file utils.ts
 *
 * Utility functions for working with Solidity ABI structures in TypeScript.
 * Provides tools to extract, parse, and manipulate ABI definitions for type-safe
 * interaction with smart contracts.
 */

import { Abi, AbiParameter } from 'viem'
import { TronWeb } from 'tronweb'

/**
 * Base58 alphabet used by Bitcoin, Solana, and TRON
 */
const BASE58_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'

/**
 * Generic Base58 decoder that works for both Solana and TRON addresses
 * @param base58String - The Base58 encoded string
 * @returns Buffer containing the decoded bytes
 */
function decodeBase58(base58String: string): Buffer {
  const alphabet = BASE58_ALPHABET
  const alphabetMap: { [key: string]: number } = {}

  // Create reverse mapping
  for (let i = 0; i < alphabet.length; i++) {
    alphabetMap[alphabet[i]] = i
  }

  let result = BigInt(0)
  let base = BigInt(1)

  // Process from right to left
  for (let i = base58String.length - 1; i >= 0; i--) {
    const char = base58String[i]
    if (!(char in alphabetMap)) {
      throw new Error(`Invalid character '${char}' in Base58 string`)
    }
    result += BigInt(alphabetMap[char]) * base
    base *= BigInt(58)
  }

  // Convert to hex string
  let hex = result.toString(16)
  if (hex.length % 2) {
    hex = '0' + hex
  }

  // Count leading zeros in original string
  let leadingZeros = 0
  for (const char of base58String) {
    if (char === '1') leadingZeros++
    else break
  }

  // Add leading zero bytes
  const leadingZeroBytes = '00'.repeat(leadingZeros)
  hex = leadingZeroBytes + hex

  return Buffer.from(hex, 'hex')
}

/**
 * Generic Base58 encoder that works for both Solana and TRON addresses
 * @param buffer - The buffer to encode
 * @returns Base58 encoded string
 */
function encodeBase58(buffer: Buffer): string {
  const alphabet = BASE58_ALPHABET

  let result = ''
  let num = BigInt('0x' + buffer.toString('hex'))

  while (num > 0) {
    const remainder = num % BigInt(58)
    result = alphabet[Number(remainder)] + result
    num = num / BigInt(58)
  }

  // Handle leading zeros
  for (let i = 0; i < buffer.length && buffer[i] === 0; i++) {
    result = '1' + result
  }

  return result
}

/**
 * Detects whether a Base58 address is likely a TRON or Solana address
 * @param base58Address - The Base58 address to analyze
 * @returns 'tron' | 'solana' | 'unknown'
 */
function detectAddressType(base58Address: string): 'tron' | 'solana' | 'unknown' {
  try {
    // Try TRON first - TRON addresses typically start with 'T' and can be validated by TronWeb
    if (base58Address.startsWith('T')) {
      TronWeb.address.toHex(base58Address)
      return 'tron'
    }

    // For other addresses, check the decoded byte length
    const decoded = decodeBase58(base58Address)

    // Solana addresses are 32 bytes when decoded
    if (decoded.length === 32) {
      return 'solana'
    }

    // TRON addresses are 21 bytes when decoded (20 bytes + 1 network byte)
    if (decoded.length === 21 && decoded[0] === 0x41) {
      return 'tron'
    }

    return 'unknown'
  } catch {
    return 'unknown'
  }
}

/**
 * Extracts the ABI struct definition with the given name from a contract ABI
 *
 * This function enables type-safe extraction of Solidity struct definitions from
 * contract ABIs, which is essential for encoding and decoding complex data structures.
 *
 * @param abi - The contract ABI containing the struct definition
 * @param structName - The name of the struct to extract
 * @returns The struct component definition with proper typing
 * @throws Error if the struct is not found in the ABI
 */
export function extractAbiStruct<
  AbiExt extends Abi,
  AbiReturn extends readonly AbiParameter[],
>(abi: AbiExt, structName: string): AbiReturn {
  const obj = extractAbiStructRecursive<AbiExt, AbiReturn>(abi, structName)
  if (!obj) {
    throw ExtractAbiStructFailed(structName)
  }
  // @ts-expect-error components is always present for structs
  return obj.components as AbiReturn
}
/**
 * Recursively searches through an ABI definition to find a struct with the specified name.
 * This helper function powers the extractAbiStruct function by traversing the nested ABI structure,
 * looking through inputs and components fields to find matching struct definitions.
 *
 * @param params - The ABI or ABI fragment to search through
 * @param structName - The name of the struct to find in the ABI
 * @returns The found struct definition or undefined if not found
 *
 * @internal This is an internal helper function used by extractAbiStruct
 */
function extractAbiStructRecursive<
  AbiExt extends Abi,
  AbiReturn extends readonly AbiParameter[],
>(abi: AbiExt, structName: string): AbiReturn | undefined {
  for (const item of abi) {
    const obj = item as any
    if (obj.name === structName) {
      return obj as AbiReturn
    }
    if (obj.inputs) {
      const result = extractAbiStructRecursive(obj.inputs, structName)
      if (result) {
        return result as AbiReturn
      }
    }
    if (obj.components) {
      const result = extractAbiStructRecursive(obj.components, structName)
      if (result) {
        return result as AbiReturn
      }
    }
  }
}

/**
 * Creates a standardized error object when a struct extraction fails.
 * This function provides consistent error messaging when a requested struct
 * cannot be found in the provided ABI, making debugging easier.
 *
 * @param structName - The name of the struct that could not be found
 * @returns Error object with descriptive message about the extraction failure
 *
 * @internal This is an internal helper function used by extractAbiStruct
 */
function ExtractAbiStructFailed(structName: string) {
  return new Error(`Could not extract the structure from abi: ${structName}`)
}

/**
 * Converts a Base58 address string to its hex representation.
 * This function supports both TRON and Solana addresses, automatically detecting
 * the address type and handling the conversion appropriately.
 *
 * @param base58Address - The Base58 encoded address string
 * @returns The hex representation with 0x prefix, padded to 32 bytes (64 hex characters)
 * @throws Error if the Base58 address is invalid or conversion fails
 *
 * @example
 * ```typescript
 * // TRON address
 * const tronHex = base58ToHex("TQh8ig6rmuMqb5u8efU5LDvoott1oLzoqu")
 * console.log(tronHex) // "0x000000000000000000000000a17fa8126b6a12feb2fe9c19f618fe04d7329074"
 *
 * // Solana address
 * const solanaHex = base58ToHex("C34z78p3WtkDZoxtBqiKgeuC71rbnv2H7koqHmb5Eo3M")
 * console.log(solanaHex) // "0xa3f83922f3081c229a9f7ff240f29f34a3548e8c7f05b6202d0d7df3de781788"
 * ```
 */
export function base58ToHex(base58Address: string): string {
  try {
    const addressType = detectAddressType(base58Address)

    if (addressType === 'tron') {
      // Use TronWeb for TRON addresses
      const hexAddress = TronWeb.address.toHex(base58Address)
      let cleanHex = hexAddress.startsWith('0x') ? hexAddress.slice(2) : hexAddress

      // Remove the TRON network byte (0x41 for mainnet) to get the 20-byte address
      if (cleanHex.length === 42 && cleanHex.startsWith('41')) {
        cleanHex = cleanHex.slice(2)
      }

      // Pad to 64 characters (32 bytes)
      const paddedHex = cleanHex.padStart(64, '0')
      return `0x${paddedHex}`
    } else {
      // Use generic Base58 decoding for Solana and other addresses
      const decoded = decodeBase58(base58Address)
      let hex = decoded.toString('hex')

      // Ensure we have 64 characters (32 bytes)
      if (hex.length < 64) {
        hex = hex.padStart(64, '0')
      } else if (hex.length > 64) {
        // If longer than 32 bytes, take the last 32 bytes
        hex = hex.slice(-64)
      }

      return `0x${hex}`
    }
  } catch (error) {
    throw new Error(`Failed to convert Base58 address to hex: ${base58Address}. ${(error as Error).message}`)
  }
}

/**
 * Converts a hex address string to its Base58 representation.
 * This function supports both TRON and Solana address formats, with automatic detection
 * based on the hex input length and content.
 *
 * @param hexAddress - The hex encoded address string with or without 0x prefix
 * @param targetFormat - Optional format specification ('tron' | 'solana' | 'auto')
 * @returns The Base58 representation
 * @throws Error if the hex address is invalid or conversion fails
 *
 * @example
 * ```typescript
 * // TRON address (20 bytes padded to 32 bytes)
 * const tronAddress = hexToBase58("0x000000000000000000000000a17fa8126b6a12feb2fe9c19f618fe04d7329074")
 * console.log(tronAddress) // "TQh8ig6rmuMqb5u8efU5LDvoott1oLzoqu"
 *
 * // Solana address (32 bytes)
 * const solanaAddress = hexToBase58("0xa3f83922f3081c229a9f7ff240f29f34a3548e8c7f05b6202d0d7df3de781788")
 * console.log(solanaAddress) // "C34z78p3WtkDZoxtBqiKgeuC71rbnv2H7koqHmb5Eo3M"
 * ```
 */
export function hexToBase58(hexAddress: string, targetFormat: 'tron' | 'solana' | 'auto' = 'auto'): string {
  try {
    // Clean the hex string - remove 0x prefix if present
    let cleanHex = hexAddress.startsWith('0x') ? hexAddress.slice(2) : hexAddress

    // Determine the target format if auto-detection is requested
    let format = targetFormat
    if (format === 'auto') {
      // Detect format based on hex characteristics
      if (cleanHex.length === 64) {
        // Check if this looks like a padded TRON address (leading zeros + 40 char address)
        const leadingZeros = cleanHex.match(/^0+/)?.[0]?.length || 0
        const remainingHex = cleanHex.slice(leadingZeros)

        if (leadingZeros >= 24 && remainingHex.length === 40) {
          // Likely a padded TRON address (12+ leading zero bytes + 20-byte address)
          format = 'tron'
        } else if (cleanHex.match(/^[0-9a-fA-F]{64}$/) && !cleanHex.startsWith('000000000000000000000000')) {
          // Full 32-byte hex without excessive leading zeros - likely Solana
          format = 'solana'
        } else {
          // Default to Solana for 32-byte addresses
          format = 'solana'
        }
      } else if (cleanHex.length === 40) {
        // 20-byte address, assume TRON
        format = 'tron'
      } else {
        throw new Error(`Unsupported hex address length: ${cleanHex.length} characters`)
      }
    }

    if (format === 'tron') {
      // TRON address handling
      let addressHex = cleanHex

      // For 64-character hex, extract the last 40 characters (20 bytes)
      if (addressHex.length === 64) {
        addressHex = addressHex.slice(-40)
      }

      // Ensure we have a valid 40-character hex string for a 20-byte address
      if (addressHex.length !== 40) {
        throw new Error(`Invalid hex address length for TRON: expected 40 characters, got ${addressHex.length}`)
      }

      // Add TRON network byte (0x41 for mainnet) to the address
      const tronHexWithNetworkByte = `41${addressHex}`

      // Convert hex address to Base58 using TronWeb
      return TronWeb.address.fromHex(tronHexWithNetworkByte)
    } else {
      // Solana address handling
      let addressHex = cleanHex

      // Ensure we have exactly 64 characters (32 bytes)
      if (addressHex.length < 64) {
        addressHex = addressHex.padStart(64, '0')
      } else if (addressHex.length > 64) {
        // If longer than 32 bytes, take the last 32 bytes
        addressHex = addressHex.slice(-64)
      }

      // Convert hex to buffer and encode as Base58
      const buffer = Buffer.from(addressHex, 'hex')
      return encodeBase58(buffer)
    }
  } catch (error) {
    throw new Error(`Failed to convert hex address to Base58: ${hexAddress}. ${(error as Error).message}`)
  }
}
