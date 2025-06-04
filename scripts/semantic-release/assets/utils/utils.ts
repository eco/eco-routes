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
