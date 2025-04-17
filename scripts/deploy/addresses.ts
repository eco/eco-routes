import * as fs from 'fs'
import * as path from 'path'
import { merge } from 'lodash'
import { Hex } from 'viem'

interface AddressBook {
  [network: string]: {
    [key: string]: string
  }
}
export const PRE_SUFFIX = '-pre'
export const jsonFileName = 'deployAddresses.json'
export const jsonFilePath = path.join(__dirname, `../../build/${jsonFileName}`)
export const buildDir = path.join(__dirname, '../../build')
export const buildSrcDir = path.join(buildDir, '/src')
export const tsFilePath = path.join(buildSrcDir, '/index.ts')
export const csvFilePath = path.join(
  __dirname,
  '../../build/deployAddresses.csv',
)
export const saltFileName = 'salt.json'
export const saltPath = path.join(__dirname, `../../build/${saltFileName}`)
export function createFile(path: string = jsonFilePath) {
  if (fs.existsSync(path)) {
    console.log('Addresses file already exists: ', path)
  } else {
    console.log('Creating addresses file: ', path)
    fs.writeFileSync(path, JSON.stringify({}), 'utf8')
  }
}

export function getJsonFromFile<T>(path: string = jsonFilePath): T {
  if (fs.existsSync(path)) {
    const fileContent = fs.readFileSync(path, 'utf8')
    return JSON.parse(fileContent)
  } else {
    createFile(path)
    return getJsonFromFile<T>(path)
  }
}

export function mergeAddresses(ads: AddressBook, path: string = jsonFilePath) {
  const addresses: AddressBook = getJsonFromFile<AddressBook>(path)

  fs.writeFileSync(path, JSON.stringify(merge(addresses, ads)), 'utf8')
}

export type JsonConfig = {
  chainId: number
  pre?: boolean
}

/**
 * Adds a new address to the address json file
 * @param deployNetwork the network of the deployed contract
 * @param key the network id
 * @param value the deployed contract address
 */
export function addJsonAddress(
  deployNetwork: JsonConfig,
  key: string,
  value: string,
) {
  const addresses: AddressBook = getJsonFromFile<AddressBook>()
  const ck = deployNetwork.chainId.toString()
  const chainKey = deployNetwork.pre ? ck + PRE_SUFFIX : ck
  addresses[chainKey] = addresses[chainKey] || {}
  addresses[chainKey][key] = value
  fs.writeFileSync(jsonFilePath, JSON.stringify(addresses), 'utf8')
}
export type SaltsType = {
  salt: Hex
  saltPre: Hex
}

export function saveDeploySalts(salts: SaltsType) {
  createFile(saltPath)
  fs.writeFileSync(saltPath, JSON.stringify(salts), 'utf8')
}

/**
 * Transforms the addresses json file into a typescript file
 * with the correct imports, exports, and types.
 */
export function transformAddresses() {
  console.log('Transforming addresses into typescript index.ts file')
  const name = 'EcoProtocolAddresses'
  // Create output directory if it doesn't exist
  fs.mkdirSync(buildSrcDir, { recursive: true })
  
  const addresses = JSON.parse(fs.readFileSync(jsonFilePath, 'utf-8'))
  const importsExports = `export * from './abi'\nexport * from './utils'\n`
  const types = `
// Viem Hex like type
type Hex = \`0x\${string}\`

/**
 * The eco protocol chain configuration type. Represents
 * all the deployed contracts on a chain.
 * 
 * @packageDocumentation
 * @module index
 */
export type EcoChainConfig = {
  Prover?: Hex
  IntentSource: Hex
  Inbox: Hex
  HyperProver: Hex
}

/**
 * The chain ids for the eco protocol
 * 
 * @packageDocumentation
 * @module index
 */
export type EcoChainIds = ${formatAddressTypes(addresses)}\n\n`
  const comments = `/**
 * This file contains the addresses of the contracts deployed on the EcoProtocol network
 * for the current npm package release. The addresses are generated by the deploy script.
 * 
 * @packageDocumentation
 * @module index
*/
`
  const outputContent =
    importsExports +
    types +
    comments +
    `export const ${name}: Record<EcoChainIds, EcoChainConfig> = \n${formatObjectWithoutQuotes(addresses, 0, true)} as const\n`
  fs.writeFileSync(tsFilePath, outputContent, 'utf-8')
}

// This function formats an object with quotes around the keys and indents per level by 2 spaces
function formatAddressTypes(obj: Record<string, any>): string {
  return Object.keys(obj)
    .map((key) => `"${key}"`)
    .join(' | ')
}

// This function formats an object without quotes around the keys and indents per level by 2 spaces
function formatObjectWithoutQuotes(
  obj: Record<string, any>,
  indentLevel = 0,
  rootLevel = false,
): string {
  const indent = ' '.repeat(indentLevel * 2) // 2 spaces per level
  const nestedIndent = ' '.repeat((indentLevel + 2) * 2)

  const formatValue = (value: any): string => {
    if (typeof value === 'object' && value !== null)
      return formatObjectWithoutQuotes(value, indentLevel + 1) // Recursive with increased indent
    return JSON.stringify(value) // For numbers, arrays, etc.
  }

  const entries = Object.entries(obj)
    .map(([key, value]) => {
      return `${nestedIndent}"${key}": ${formatValue(value)}`
    })
    .join(',\n')
  const frontIndent = rootLevel ? '  ' : ''
  return `${frontIndent}{\n${entries}\n${indent}  }`
}
