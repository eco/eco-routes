/**
 * @file sr-build-package.ts
 *
 * Responsible for building the TypeScript package for distribution to npm.
 * This process includes:
 * 
 * 1. Collecting Solidity ABIs and contract artifacts for TypeScript consumption
 * 2. Creating type-safe contract interfaces and address exports
 * 3. Formatting deployed addresses for different chains
 * 4. Generating a CSV export of contract addresses for non-code consumption
 * 5. Setting up proper package.json with the right dependencies and metadata
 * 6. Compiling TypeScript code for distribution
 *
 * The resulting package enables developers to easily interact with the protocol's
 * deployed contracts with full type safety and current addresses.
 */

import fs from 'fs'
import path from 'path'
import { exec } from 'child_process'
import { promisify } from 'util'
import { stringify as stringifyCSV } from 'csv-stringify/sync'
import { SemanticContext } from './sr-prepare'
import semverUtils from 'semver-utils'
import { getPackageInfo, Logger } from './helpers'
import { getBuildDirPath, PACKAGE } from './constants'
import { getGitHashShort } from './solidity-version-updater'

// Define the contract types that form our chain configuration
// This is used for both CSV headers and TypeScript type definitions
export const CONTRACT_TYPES = ['IntentSource', 'Inbox', 'HyperProver'] as const

const execPromise = promisify(exec)

/**
 * Represents the structure of the addresses.json file
 * with chain IDs as keys and contract names/addresses as values
 */
interface AddressesJson {
  [chainId: string]: {
    [contractName: string]: string
  }
}

/**
 * Represents the structure of an ABI file
 * Contains contract interface details needed for TypeScript code generation
 */
interface AbiFile {
  abi: any[]
  bytecode: string
  deployedBytecode: string
  contractName: string
  sourceName: string
}

/**
 * Builds the complete TypeScript package for distribution
 * This is the main entry point for the package building process that orchestrates
 * all the steps needed to create a distributable npm package with contract ABIs,
 * addresses, and TypeScript definitions
 * 
 * @param context The semantic release context containing version and logging info
 */
export async function buildPackage(context: SemanticContext): Promise<void> {
  const { nextRelease, logger, cwd } = context

  try {
    // Determine version for npm package retrieval
    const version = nextRelease!.version
    const parsedVersion = semverUtils.parse(version)
    const majorMinorVersion = `${parsedVersion.major}.${parsedVersion.minor}`

    logger.log(`Building package for version ${version}`)

    // Get local deployment addresses
    const localAddressesPath = path.join(cwd, 'build', 'deployAddresses.json')
    let deployedAddresses: AddressesJson = {}

    if (fs.existsSync(localAddressesPath)) {
      const localAddressesContent = fs.readFileSync(localAddressesPath, 'utf-8')
      deployedAddresses = JSON.parse(localAddressesContent)
    } else {
      logger.error(`No local addresses found in file at ${localAddressesPath}`)
      return
    }

    // Create build directory
    const buildDir = path.join(cwd, 'build')
    fs.mkdirSync(buildDir, { recursive: true })

    // Create necessary subdirectories
    fs.mkdirSync(path.join(buildDir, 'src', 'abi', 'contracts'), {
      recursive: true,
    })
    fs.mkdirSync(path.join(buildDir, 'src', 'abi', 'interfaces'), {
      recursive: true,
    })
    fs.mkdirSync(path.join(buildDir, 'src', 'utils'), { recursive: true })

    // Copy ABIs using the approach from prepack.sh
    logger.log('Copying ABI files')
    await execPromise(
      `cp ${cwd}/artifacts/contracts/**/*.json ${buildDir}/src/abi/contracts`,
    )
    await execPromise(
      `cp ${cwd}/artifacts/contracts/interfaces/**/*.json ${buildDir}/src/abi/interfaces`,
    )

    // Remove debug files from all directories recursively
    await execPromise(
      `find ${buildDir}/src/abi -name "*.dbg.json" -type f -delete`,
    )

    // Copy the solidity files, excluding test, tools, and build directories
    logger.log('Copying Solidity files')
    const contractsDir = path.join(cwd, 'contracts')
    const solidityFiles = listFilesRecursively(contractsDir)

    // Define directories to skip
    const skipDirs = ['test', 'tools', 'build']

    solidityFiles
      .filter(
        (file) =>
          !skipDirs.some(
            (dir) => file.startsWith(dir) || file.includes(`/${dir}/`),
          ),
      )
      .forEach((file) => {
        const sourcePath = path.join(contractsDir, file)
        const targetPath = path.join(buildDir, 'src', file)
        fs.mkdirSync(path.dirname(targetPath), { recursive: true })
        fs.copyFileSync(sourcePath, targetPath)
        logger.log(`Copied ${sourcePath} to ${targetPath}`)
      })
    // Generate TypeScript files from ABI JSON files
    logger.log('Generating TypeScript files from ABI JSON files')
    generateAbiTypeScriptFiles(buildDir, logger)

    // Copy utility files from semantic-release/assets/utils
    logger.log('Copying utility files from assets/utils')
    await execPromise(
      `cp ${cwd}/scripts/semantic-release/assets/utils/*.ts ${buildDir}/src/utils/`,
    )

    // Generate CSV file from addresses
    generateCsvFile(deployedAddresses, buildDir, logger)

    // Generate index.ts file
    generateIndexFile(deployedAddresses, buildDir, version, logger)

    // Copy other necessary files
    copyOtherPackageFiles(buildDir, context)

    // Create tsconfig.json for TypeScript compilation
    createTsConfig(buildDir, logger)

    // Compile TypeScript files
    logger.log('Compiling TypeScript files...')
    await execPromise(`cd ${buildDir} && tsc`)

    logger.log('✅ Package build completed successfully')
  } catch (error) {
    logger.error('❌ Package build failed')
    logger.error((error as Error).message)
    throw error
  }
}

/**
 * Generates TypeScript files from ABI JSON files
 * Converts raw contract ABI JSON files into fully typed TypeScript modules
 * with proper typing for viem integration. Creates index files for easy imports
 * and removes the original JSON files to keep the package clean.
 * 
 * @param buildDir The directory to build in
 * @param logger The logger to use for output messages
 */
function generateAbiTypeScriptFiles(buildDir: string, logger: Logger): void {
  // Directory containing the JSON files
  const abiParentDir = path.join(buildDir, 'src', 'abi')
  const dirs = [
    path.join(abiParentDir, 'contracts'),
    path.join(abiParentDir, 'interfaces'),
  ]

  let mainIndexContent = `// Export all ABIs with proper typing for viem\n`
  logger.log('Starting ABI exports')

  dirs.forEach((abiDir) => {
    logger.log(`Processing directory: ${abiDir}`)

    // Read through the directory and get all .json files
    const jsonFiles = fs
      .readdirSync(abiDir)
      .filter((file) => file.endsWith('.json'))

    // Read each JSON file and parse its content
    const data = jsonFiles.reduce((acc: AbiFile[], file) => {
      const filePath = path.join(abiDir, file)
      const fileContent = fs.readFileSync(filePath, 'utf-8')
      const abiFile = JSON.parse(fileContent)
      acc.push({
        abi: abiFile.abi,
        bytecode: abiFile.bytecode,
        deployedBytecode: abiFile.deployedBytecode,
        contractName: abiFile.contractName,
        sourceName: abiFile.sourceName,
      })
      // Remove the JSON file after processing
      fs.unlinkSync(filePath)
      return acc
    }, [])

    let indexContent = `// Contract ABIs for ${path.basename(abiDir)}\n`
    const indexFilePath = path.join(abiDir, 'index.ts')

    // Generate the TypeScript code
    data.forEach((abiFile: AbiFile) => {
      const abiVarName = `${abiFile.contractName}Abi`
      const bytecodeVarName = `${abiFile.contractName}Bytecode`
      const deployedBytecodeVarName = `${abiFile.contractName}DeployedBytecode`

      // Add export to directory index
      indexContent += `export * from './${abiFile.contractName}'\n`

      // Generate contract ABI file with proper typing
      const outputContent =
        `/**\n * ABI for the ${abiFile.contractName} contract\n */\n` +
        `export const ${abiVarName} = ${JSON.stringify(abiFile.abi, null, 2)} as const\n\n` +
        `/**\n * Type-safe ABI for the ${abiFile.contractName} contract\n */\n` +
        `export type ${abiFile.contractName}AbiType = typeof ${abiVarName}\n\n` +
        `/**\n * Bytecode for the ${abiFile.contractName} contract\n */\n` +
        `export const ${bytecodeVarName} = "${abiFile.bytecode}"\n\n` +
        `/**\n * Deployed bytecode for the ${abiFile.contractName} contract\n */\n` +
        `export const ${deployedBytecodeVarName} = "${abiFile.deployedBytecode}"\n`

      const filePath = path.join(abiDir, `${abiFile.contractName}.ts`)
      fs.writeFileSync(filePath, outputContent, 'utf-8')
    })

    fs.writeFileSync(indexFilePath, indexContent, 'utf-8')
    mainIndexContent += `export * from './${path.basename(abiDir)}'\n`
  })

  // Create index file that re-exports all contract ABIs
  fs.writeFileSync(
    path.join(abiParentDir, 'index.ts'),
    mainIndexContent,
    'utf-8',
  )

  logger.log('Finished ABI exports')
}

/**
 * Generates a CSV file from the addresses JSON
 * Creates a human-readable CSV export of deployed contract addresses
 * by chain ID. This allows non-developers to easily access contract addresses
 * without parsing JSON or writing code.
 * 
 * @param addresses Object containing chain IDs and contract addresses
 * @param buildDir Directory to store the output CSV
 * @param logger The logger instance for output messages
 */
function generateCsvFile(
  addresses: AddressesJson,
  buildDir: string,
  logger: Logger,
): void {
  const rows = []

  // Add header row with specified format using the shared CONTRACT_TYPES
  const headers = ['Chain', ...CONTRACT_TYPES]
  rows.push(headers)

  // Add data rows
  for (const [chainId, contracts] of Object.entries(addresses)) {
    // Create a row for each chain
    const row = [chainId]

    // Add values for each contract type from the shared constant
    CONTRACT_TYPES.forEach((contractType) => {
      row.push(contracts[contractType] || '')
    })

    rows.push(row)
  }

  // Generate CSV content
  const csvContent = stringifyCSV(rows)

  // Save to file
  const csvPath = path.join(buildDir, 'deployAddresses.csv')
  fs.writeFileSync(csvPath, csvContent)

  logger.log(`CSV file saved to ${csvPath}`)
}

/**
 * Generates the main index.ts file with addresses exports
 * Creates the TypeScript entry point with type-safe exports of all contract
 * addresses and helper functions. Includes TypeScript type definitions for
 * chain configurations and utility functions to access addresses by chain ID.
 * 
 * @param addresses Object containing chain IDs and contract addresses
 * @param buildDir Directory to store the output file
 * @param version Package version number to embed in the file
 * @param logger The logger instance for output messages
 */
function generateIndexFile(
  addresses: AddressesJson,
  buildDir: string,
  version: string,
  logger: Logger,
): void {
  const gitHash = getGitHashShort()

  // Create the index content with template literals
  const indexContent = `// Generated by build script for version ${version}-${gitHash}
import { Hex } from 'viem'
export * from './abi'
export * from './utils'

/**
 * This file contains the addresses of the contracts deployed on the EcoProtocol network
 * for the current npm package release. The addresses are generated by the deploy script.
 *
 * @packageDocumentation
 * @module index
*/
export const EcoProtocolAddresses = ${JSON.stringify(addresses, null, 2)} as const;

/**
 * The eco protocol chain configuration type. Represents
 * all the deployed contracts on a chain.
 * 
 * @packageDocumentation
 * @module index
 */
export type EcoChainConfig = {
  ${CONTRACT_TYPES.map((type) => `${type}: Hex`).join(',\n  ')}
}
export type EcoChainIds = keyof typeof EcoProtocolAddresses;
export type ContractName<T extends EcoChainIds> = keyof typeof EcoProtocolAddresses[T];

export function getContractAddress<T extends EcoChainIds>(
  chainId: T,
  contractName: ContractName<T>
): Hex {
  return EcoProtocolAddresses[chainId][contractName] as Hex;
}
`

  // Create index.ts
  fs.writeFileSync(path.join(buildDir, 'src', 'index.ts'), indexContent)

  logger.log(`Index files generated in ${buildDir}`)
}

/**
 * Lists all files in a directory recursively
 * Utility function to find all files within a directory structure
 * maintaining relative paths, which is useful for copying contract source
 * files while preserving directory structure.
 * 
 * @param dir Directory to list files from
 * @returns Array of file paths relative to the provided directory
 */
function listFilesRecursively(dir: string): string[] {
  // Import listFilesRecursively from helpers to avoid code duplication
  // Instead of importing directly at the top to avoid circular dependencies
  const helpers = require('./helpers');
  return helpers.listFilesRecursively(dir);
}


function copyOtherPackageFiles(
  buildDir: string,
  context: SemanticContext
): void {
  const { nextRelease, logger, cwd } = context

  // Copy common files like README, LICENSE, etc.
  const filesToCopy = [
    {
      source: path.join(cwd, 'package.json'),
      target: path.join(buildDir, 'package.json'),
    },
    {
      source: path.join(cwd, 'README.md'),
      target: path.join(buildDir, 'README.md'),
    },
    {
      source: path.join(cwd, 'LICENSE'),
      target: path.join(buildDir, 'LICENSE'),
    },
  ]

  for (const file of filesToCopy) {
    if (fs.existsSync(file.source)) {
      fs.copyFileSync(file.source, file.target)
      logger.log(`Copied ${file.source} to ${file.target}`)
    }
  }

  // Create package.json for the build
  setPublishingPackage({ logger, cwd, nextRelease }, PACKAGE.ROUTES_PACKAGE_NAME)
}

/**
 * Creates tsconfig.json for TypeScript compilation
 * Sets up the TypeScript compiler configuration for the npm package
 * with the right target settings, module type, and output directory.
 * This ensures the package is built with the correct settings for
 * compatibility with various JavaScript environments.
 * 
 * @param buildDir Directory to create the config in
 * @param logger The logger instance for output messages
 */
function createTsConfig(buildDir: string, logger: Logger): void {
  const tsConfig = {
    compilerOptions: {
      target: 'es2020',
      module: 'commonjs',
      declaration: true,
      outDir: './dist',
      esModuleInterop: true,
      forceConsistentCasingInFileNames: true,
      strict: true,
      skipLibCheck: true,
      resolveJsonModule: true,
    },
    include: ['*.ts', 'src/**/*.ts'],
    exclude: ['node_modules', 'dist'],
  }

  fs.writeFileSync(
    path.join(buildDir, 'tsconfig.json'),
    JSON.stringify(tsConfig, null, 2),
  )

  logger.log('Created tsconfig.json for the build')
}


export async function setPublishingPackage(context: SemanticContext, pubLib: typeof PACKAGE[keyof typeof PACKAGE]): Promise<void> {
  const { logger, cwd, nextRelease } = context

  if (!nextRelease) {
    logger.log('No release detected, skipping TypeScript-only package creation')
    return
  }

  const buildDir = getBuildDirPath(cwd)
  // Create a TypeScript-specific package.json by modifying the existing one
  let projectPackageJson = getPackageInfo(buildDir)
  const packageJsonPath = path.join(buildDir, 'package.json')
  if (projectPackageJson) {
    logger.log(`Updating package.json for ` + pubLib)
    const defaults = {
      version: nextRelease.version,
      description: projectPackageJson.description,
      main: 'dist/index.js',
      types: 'dist/index.d.ts',
    }
    const diffs = pubLib === PACKAGE.ROUTES_PACKAGE_NAME ? {
      name: PACKAGE.ROUTES_PACKAGE_NAME,
      ...defaults,
      files: [
        'dist',
        'src',
        'deployAddresses.json',
        'deployAddresses.csv',
        '!src/abi',
        '!src/utils',
        '!src/index.ts',
      ],
    }
      :
      {
        name: PACKAGE.ROUTES_TS_PACKAGE_NAME,
        ...defaults,
        files: [
          'dist',
          'deployAddresses.json',
          'deployAddresses.csv'
        ],
        dependencies: { viem: projectPackageJson.dependencies.viem }
      }

    // Modify package.json for TypeScript build
    // Change package name to add -ts suffix
    projectPackageJson = {
      ...projectPackageJson,
      ...diffs,
    }

    // Remove some unnecessary fields
    delete projectPackageJson.devDependencies
    delete projectPackageJson.scripts

    // Write the modified package.json
    fs.writeFileSync(
      packageJsonPath,
      JSON.stringify(projectPackageJson, null, 2)
    )
    logger.log('Created package.json for the build')
  }
}
