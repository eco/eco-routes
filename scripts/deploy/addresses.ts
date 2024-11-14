import * as fs from 'fs'
import * as path from 'path'
import { DeployNetwork } from '../deloyProtocol'

interface AddressBook {
  [network: string]: {
    [key: string]: string
  }
}

// const filePath = path.join(__dirname, 'addresses.ts');
const jsonFilePath = path.join(__dirname, '../../build/jsonAddresses.json')

export function updateAddresses(
  deployNetwork: DeployNetwork,
  key: string,
  value: string,
) {
  let addresses: AddressBook = {}

  if (fs.existsSync(jsonFilePath)) {
    const fileContent = fs.readFileSync(jsonFilePath, 'utf8')
    addresses = JSON.parse(fileContent)
  }
  const ck = deployNetwork.chainId.toString()
  const chainKey = deployNetwork.pre ? ck + '-pre' : ck
  addresses[chainKey] = addresses[chainKey] || {}
  addresses[chainKey][key] = value
  fs.writeFileSync(jsonFilePath, JSON.stringify(addresses), 'utf8')
}

export function transformAddresses() {
  const tsFilePath = path.join(__dirname, '../../build/src/index.ts')
  const name = 'EcoProtocolAddresses'
  const addresses = JSON.parse(fs.readFileSync(jsonFilePath, 'utf-8'))
  const abiImports = `export * from './abi'\n`
  const comments = `/**
 * This file contains the addresses of the contracts deployed on the EcoProtocol network
 * for the current npm package release. The addresses are generated by the deploy script.
 * 
 * @packageDocumentation
 * @module index
*/
`
  const outputContent =
    abiImports +
    comments +
    `export const ${name} = \n${formatObjectWithoutQuotes(addresses)} as const\n`
  fs.writeFileSync(tsFilePath, outputContent, 'utf-8')
}

export function deleteAddressesJson() {
  fs.unlinkSync(jsonFilePath)
}

// This function formats an object without quotes around the keys and indents per level by 2 spaces
function formatObjectWithoutQuotes(
  obj: Record<string, any>,
  indentLevel = 0,
): string {
  const indent = ' '.repeat(indentLevel * 2) // 2 spaces per level
  const nestedIndent = ' '.repeat((indentLevel + 1) * 2)

  const formatValue = (value: any): string => {
    // if (typeof value === 'string') return value; // Print strings without quotes
    if (typeof value === 'object' && value !== null)
      return formatObjectWithoutQuotes(value, indentLevel + 1) // Recursive with increased indent
    return JSON.stringify(value) // For numbers, arrays, etc.
  }

  const entries = Object.entries(obj)
    .map(
      ([key, value]) =>{
        key = key.includes('-') ? `"${key}"` : key
        return `${nestedIndent}${key}: ${formatValue(value)}`
      }
    )
    .join(',\n')

  return `{\n${entries}\n${indent}}`
}

function toCamelCase(str: string): string {
  return str.replace(/-([a-z]|[A-Z])/g, (_, letter) => letter.toUpperCase())
}
