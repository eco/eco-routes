/**
 * @file utils.ts
 * 
 * Utility functions for working with Solidity ABI structures in TypeScript.
 * Provides tools to extract, parse, and manipulate ABI definitions for type-safe
 * interaction with smart contracts.
 */

import { Abi, AbiParameter } from 'viem'

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
  abi extends Abi,
  AbiReturn extends readonly AbiParameter[],
>(abi: abi, structName: string): AbiReturn {
  const obj = extractAbiStructRecursive<abi, AbiReturn>(abi, structName)
  if (!obj) {
    throw ExtractAbiStructFailed(structName)
  }
  // @ts-expect-error components is always present for structs
  return obj.components as AbiReturn
}
/**
 * Recursively extracts the ABI struct with the given name
 * @param params the abi
 * @param structName the name of the struct
 */
function extractAbiStructRecursive<
  abi extends Abi,
  AbiReturn extends readonly AbiParameter[],
>(abi: abi, structName: string): AbiReturn | undefined {
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
 * The error thrown when the struct could not be extracted from an abi
 * @param structName the name of the struct
 * @returns
 */
function ExtractAbiStructFailed(structName: string) {
  return new Error(`Could not extract the structure from abi: ${structName}`)
}
