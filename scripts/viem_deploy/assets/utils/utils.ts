import { Abi, AbiParameter } from 'viem'

/**
 * Extracts the ABI struct with the given name
 * @param params the abi
 * @param structName the name of the struct
 */
export function extractAbiStruct<
  abi extends Abi,
  AbiReturn extends readonly AbiParameter[],
>(abi: abi, structName: string): AbiReturn {
  const obj = extractAbiStructRecursive<abi, AbiReturn>(abi, structName)
  if (!obj) {
    throw ExtractAbiStructFailed(structName)
  }
  return obj
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
