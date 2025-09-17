/**
 * @file abi-struct-extractor.ts
 *
 * Utilities for extracting struct definitions from contract ABIs and generating
 * TypeScript types using abitype. This replaces manual struct definitions with
 * dynamic extraction from compiled contract artifacts.
 */

import type { AbiParameter, AbiFunction, AbiEvent } from 'abitype'

export interface ExtractedStruct {
  name: string
  parameter: AbiParameter
  usageCount: number
}

export interface StructExtractionResult {
  structs: Record<string, ExtractedStruct>
  functions: AbiFunction[]
  events: AbiEvent[]
}

/**
 * Analyzes a contract ABI to extract all struct definitions from function inputs/outputs.
 * This creates a map of struct names to their ABI parameter definitions, which can
 * be used for type inference and encoding/decoding operations.
 *
 * @param abi - The contract ABI to analyze
 * @returns Object containing extracted structs, functions, and events
 */
export function extractStructsFromAbi(
  abi: readonly any[],
): StructExtractionResult {
  const structs: Record<string, ExtractedStruct> = {}
  const functions: AbiFunction[] = []
  const events: AbiEvent[] = []

  abi.forEach((item) => {
    if (item.type === 'function') {
      functions.push(item as AbiFunction)

      // Extract structs from function inputs
      item.inputs?.forEach((input: any) => {
        extractStructFromParameter(input, structs)
      })

      // Extract structs from function outputs
      item.outputs?.forEach((output: any) => {
        extractStructFromParameter(output, structs)
      })
    } else if (item.type === 'event') {
      events.push(item as AbiEvent)

      // Extract structs from event inputs
      item.inputs?.forEach((input: any) => {
        extractStructFromParameter(input, structs)
      })
    }
  })

  return { structs, functions, events }
}

/**
 * Recursively extracts struct definitions from an ABI parameter.
 * Handles nested structs and arrays of structs.
 *
 * @param param - The ABI parameter to analyze
 * @param structs - Map to store extracted struct definitions
 */
function extractStructFromParameter(
  param: any,
  structs: Record<string, ExtractedStruct>,
): void {
  if (param.type === 'tuple' && param.name) {
    const structName = param.name

    if (structs[structName]) {
      // Increment usage count if we've seen this struct before
      structs[structName].usageCount++
    } else {
      // First time seeing this struct - check if it has meaningful components
      if (param.components && param.components.length > 0) {
        structs[structName] = {
          name: structName,
          parameter: param as AbiParameter,
          usageCount: 1,
        }
      }
    }

    // Recursively check components for nested structs
    param.components?.forEach((component: any) => {
      extractStructFromParameter(component, structs)
    })
  } else if (param.type.startsWith('tuple[')) {
    // Handle arrays of tuples
    if (param.name && param.components && param.components.length > 0) {
      const structName = param.name.replace(/\[\]$/, '') // Remove array suffix

      if (structs[structName]) {
        structs[structName].usageCount++
      } else {
        structs[structName] = {
          name: structName,
          parameter: {
            ...param,
            type: 'tuple',
            name: structName,
          } as AbiParameter,
          usageCount: 1,
        }
      }

      // Recursively check components
      param.components.forEach((component: any) => {
        extractStructFromParameter(component, structs)
      })
    }
  }
}

/**
 * Finds a specific struct definition in the extracted structs.
 *
 * @param structs - Map of extracted struct definitions
 * @param structName - Name of the struct to find
 * @returns The struct parameter or null if not found
 */
export function findStruct(
  structs: Record<string, ExtractedStruct>,
  structName: string,
): AbiParameter | null {
  const extracted = structs[structName]
  return extracted ? extracted.parameter : null
}

/**
 * Generates TypeScript type definitions from extracted struct definitions.
 *
 * @param structs - Map of extracted struct definitions
 * @param contractName - Name of the contract for prefixing types
 * @returns Generated TypeScript code as a string
 */
export function generateTypeDefinitions(
  structs: Record<string, ExtractedStruct>,
  contractName: string,
): string {
  // No imports here - they'll be handled at the file level
  let typeCode = ``

  // Generate type definitions for each struct
  Object.values(structs).forEach((extractedStruct) => {
    const { name, parameter } = extractedStruct
    const typeName = `${name}`
    const paramName = `${name}Param`
    const exportParamName = `${name}Parameter`

    typeCode += `// ${name} struct from ${contractName} contract\n`
    typeCode += `const ${paramName} = ${JSON.stringify(parameter, null, 2)} as const;\n\n`
    typeCode += `export type ${typeName} = AbiParameterToPrimitiveType<typeof ${paramName}>;\n`
    typeCode += `export const ${exportParamName} = ${paramName};\n\n`
  })

  return typeCode
}

/**
 * Generates hash utility functions for extracted structs.
 *
 * @param structs - Map of extracted struct definitions
 * @param contractName - Name of the contract for the hasher class
 * @returns Generated TypeScript hash utility code
 */
export function generateHashUtilities(
  structs: Record<string, ExtractedStruct>,
  contractName: string,
): string {
  // No imports here - they'll be handled at the file level
  let hashCode = `/**\n * Hash utilities for ${contractName} contract structs\n */\n`
  hashCode += `export class ${contractName}Hasher {\n`

  // Generate hash methods for each struct
  Object.values(structs).forEach((extractedStruct) => {
    const { name, parameter } = extractedStruct
    const methodName = `hash${name.charAt(0).toUpperCase() + name.slice(1)}`
    const paramName = `${name}Parameter`

    hashCode += `  /**\n`
    hashCode += `   * Calculates the keccak256 hash of a ${name} struct\n`
    hashCode += `   */\n`
    hashCode += `  static ${methodName}(${name.toLowerCase()}: ${name}): Hex {\n`
    hashCode += `    const ${paramName} = ${JSON.stringify(parameter, null, 4)};\n`
    hashCode += `    const encoded = encodeAbiParameters([${paramName}], [${name.toLowerCase()}]);\n`
    hashCode += `    return keccak256(encoded);\n`
    hashCode += `  }\n\n`
  })

  hashCode += `}\n`

  return hashCode
}

/**
 * Generates model classes with encoding/decoding capabilities for extracted structs.
 *
 * @param structs - Map of extracted struct definitions
 * @param contractName - Name of the contract for the model classes
 * @returns Generated TypeScript model class code
 */
export function generateModelClasses(
  structs: Record<string, ExtractedStruct>,
  contractName: string,
): string {
  // No imports here - they'll be handled at the file level
  let modelCode = ``

  // Generate model classes for each struct
  Object.values(structs).forEach((extractedStruct) => {
    const { name, parameter } = extractedStruct
    const className = `${name}Model`
    const paramName = `${name}Parameter`

    modelCode += `/**\n`
    modelCode += ` * Model class for ${name} struct with encoding/decoding and hashing capabilities\n`
    modelCode += ` */\n`
    modelCode += `export class ${className} {\n`
    modelCode += `  private static readonly ${paramName} = ${JSON.stringify(parameter, null, 4)};\n\n`
    modelCode += `  constructor(readonly value: ${name}) {}\n\n`

    // Hash method
    modelCode += `  /**\n`
    modelCode += `   * Calculate the keccak256 hash of this ${name}\n`
    modelCode += `   */\n`
    modelCode += `  hash(): Hex {\n`
    modelCode += `    const encoded = encodeAbiParameters([${className}.${paramName}], [this.value]);\n`
    modelCode += `    return keccak256(encoded);\n`
    modelCode += `  }\n\n`

    // Encode method
    modelCode += `  /**\n`
    modelCode += `   * Encode this ${name} to calldata\n`
    modelCode += `   */\n`
    modelCode += `  toCalldata(): Hex {\n`
    modelCode += `    return encodeAbiParameters([${className}.${paramName}], [this.value]);\n`
    modelCode += `  }\n\n`

    // Static decode method
    modelCode += `  /**\n`
    modelCode += `   * Decode ${name} from calldata\n`
    modelCode += `   */\n`
    modelCode += `  static fromCalldata(data: Hex): ${className} {\n`
    modelCode += `    const [decoded] = decodeAbiParameters([${className}.${paramName}], data);\n`
    modelCode += `    return new ${className}(decoded as ${name});\n`
    modelCode += `  }\n`

    modelCode += `}\n\n`
  })

  return modelCode
}
