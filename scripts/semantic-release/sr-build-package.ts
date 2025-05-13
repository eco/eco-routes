/**
 * @file sr-build-package.ts
 *
 * Manages the build process for the eco-routes npm package, transforming
 * compiled contracts and deployment information into a structured package
 * that can be consumed by client applications.
 *
 * This process includes:
 * 1. Collecting and processing Solidity ABIs from contract artifacts
 * 2. Creating type-safe TypeScript interfaces for contract interaction
 * 3. Formatting deployed addresses across multiple chains and environments
 * 4. Generating address exports for different network configurations
 * 5. Setting up package.json with appropriate metadata and dependencies
 * 6. Integrating documentation and type definitions for developer experience
 * 7. Compiling and packaging TypeScript code for distribution
 *
 * The resulting npm package enables developers to easily interact with the protocol's
 * deployed contracts with full type safety, consistent addressing across chains,
 * and proper versioning that matches the deployed contract implementations.
 */

import fs from 'fs'
import path from 'path'
import { exec } from 'child_process'
import { promisify } from 'util'
// eslint-disable-next-line node/no-missing-import
import { stringify as stringifyCSV } from 'csv-stringify/sync'
import { SemanticContext } from './sr-prepare'
import { getPackageInfo, Logger } from './helpers'
import { getBuildDirPath, PACKAGE } from './constants'
import { getGitHashShort } from './solidity-version-updater'

// Define the contract types that form our chain configuration
// This is used for both CSV headers and TypeScript type definitions
export const CONTRACT_TYPES = [
  'IntentSource',
  'Inbox',
  'HyperProver',
  'MetaProver',
] as const

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
 * Builds the complete TypeScript package for distribution to npm.
 * This is the main entry point for the package building process that orchestrates
 * all the steps needed to create a distributable npm package with contract ABIs,
 * addresses, and TypeScript definitions.
 *
 * The build process includes:
 * 1. Collecting compiled contract artifacts (ABIs, bytecode)
 * 2. Copying and filtering Solidity source files
 * 3. Generating TypeScript type definitions from ABIs
 * 4. Creating deployment address exports for all chains
 * 5. Building distributable TypeScript modules
 * 6. Packaging everything with proper metadata for npm
 *
 * @param context - The semantic release context containing version and logging info
 * @returns Promise that resolves when the package build is complete
 *
 * @throws Will throw an error if any part of the build process fails
 */
export async function buildPackage(context: SemanticContext): Promise<void> {
  const { nextRelease, logger, cwd } = context

  try {
    // Determine version for npm package retrieval
    const version = nextRelease!.version
    const channel = nextRelease!.channel || 'latest'

    logger.log(
      `Building package for version ${version} with channel ${channel}`,
    )

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
 * Generates TypeScript files from ABI JSON files, creating type-safe contract interfaces.
 * Converts raw contract ABI JSON files into fully typed TypeScript modules
 * with proper typing for viem integration. Creates index files for easy imports
 * and removes the original JSON files to keep the package clean.
 *
 * The generated TypeScript files include:
 * - Exported ABI constants with proper typing
 * - Type definitions for contract interactions
 * - Bytecode exports for contract deployment
 * - Hierarchical index files for organized imports
 *
 * @param buildDir - The directory where build artifacts and generated files should be placed
 * @param logger - The logger instance to use for output messages and errors
 *
 * @example
 * // Generate TypeScript files from ABIs in the build directory
 * generateAbiTypeScriptFiles('/path/to/build', logger);
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
 * Generates a human-readable CSV file from the addresses JSON for easy reference.
 * Creates a standardized export of deployed contract addresses organized by chain ID,
 * allowing non-developers to easily access and reference contract addresses
 * without parsing JSON or writing code.
 *
 * The CSV format follows a consistent structure with:
 * - Headers: ChainID, IntentSource, Inbox, HyperProver, MetaProver
 * - One row per chain ID with all corresponding contract addresses
 * - Empty cells for contract types not deployed on a particular chain
 *
 * @param addresses - Object containing chain IDs and contract addresses mapping
 * @param buildDir - Directory to store the output CSV file
 * @param logger - The logger instance for output messages and errors
 *
 * @example
 * // Generate CSV from deployment addresses
 * generateCsvFile(deployedAddresses, '/path/to/build', logger);
 */
function generateCsvFile(
  addresses: AddressesJson,
  buildDir: string,
  logger: Logger,
): void {
  const rows = []

  // Add header row with specified format using the shared CONTRACT_TYPES
  const headers = ['ChainID', ...CONTRACT_TYPES]
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
 * Generates the main index.ts file with type-safe contract addresses exports.
 * Creates the TypeScript entry point with all necessary exports including
 * ABIs, utilities, and contract addresses with proper TypeScript typing.
 *
 * The generated index file includes:
 * - All deployed contract addresses organized by chain ID
 * - Type definitions for chain configurations and contract references
 * - Helper functions for type-safe contract address retrieval
 * - Version and git hash information for traceability
 * - Re-exports of ABI and utility modules
 *
 * @param addresses - Object containing chain IDs and contract addresses mapping
 * @param buildDir - Directory to store the generated index.ts file
 * @param version - Package version number to embed in the file for reference
 * @param logger - The logger instance for output messages and errors
 *
 * @example
 * // Generate main index.ts file with contract addresses
 * generateIndexFile(addresses, '/path/to/build', '1.2.3', logger);
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

/**
 * The chain ids of the eco protocol, including the different environments. 
 */
export type EcoChainIdsEnv = keyof typeof EcoProtocolAddresses

/**
 * The chain ids of the eco protocol, exluding the different environments. 
 */
export type EcoChainIds = Exclude<EcoChainIdsEnv, ${'`${number}`'}> extends ${'`${infer N extends number}`'} ? N : never;
export type ContractName<T extends EcoChainIdsEnv> = keyof typeof EcoProtocolAddresses[T];

/**
 * An array of all the chain ids of the eco protocol, excluding the different environments.
 */
export const EcoChainIdsArray: EcoChainIds[] = Object.keys(EcoProtocolAddresses).filter(
  (chainId): chainId is EcoChainIds => !chainId.includes('-')
);
export function getContractAddress<T extends EcoChainIdsEnv>(
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
  const helpers = require('./helpers')
  return helpers.listFilesRecursively(dir)
}

function copyOtherPackageFiles(
  buildDir: string,
  context: SemanticContext,
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
  setPublishingPackage(
    { logger, cwd, nextRelease },
    PACKAGE.ROUTES_PACKAGE_NAME,
  )
}

/**
 * Creates a tsconfig.json file for TypeScript compilation of the package.
 * Sets up the TypeScript compiler configuration for the npm package
 * with the right target settings, module type, and output directory.
 *
 * This configuration ensures the package is built with the correct settings for
 * compatibility with various JavaScript environments and includes:
 * - ES2020 target for modern JavaScript features
 * - CommonJS module format for maximum compatibility
 * - Declaration file generation for type safety
 * - Strict type checking for code quality
 * - Proper file inclusion/exclusion patterns
 *
 * @param buildDir - Directory where the tsconfig.json file should be created
 * @param logger - The logger instance for output messages and errors
 *
 * @example
 * // Create tsconfig.json in the build directory
 * createTsConfig('/path/to/build', logger);
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

/**
 * Prepares the package.json for publishing by modifying it with the correct metadata
 * for the specified package type (either main package or TypeScript-only package).
 *
 * This function customizes the package.json with appropriate fields including:
 * - Package name (either eco-routes or eco-routes-ts)
 * - Current version from semantic release
 * - Module entry points and type definitions
 * - Files to include in the published package
 * - Dependency specifications
 *
 * The function maintains different configurations for the main package (with Solidity files)
 * and the TypeScript-only package for different use cases.
 *
 * @param context - Semantic release context with version and logging information
 * @param pubLib - Package identifier from PACKAGE constants defining which variant to build
 * @returns Promise that resolves when package.json has been updated
 *
 * @example
 * // Set up the main package with full Solidity files
 * await setPublishingPackage(context, PACKAGE.ROUTES_PACKAGE_NAME);
 *
 * // Set up the TypeScript-only package
 * await setPublishingPackage(context, PACKAGE.ROUTES_TS_PACKAGE_NAME);
 */
export async function setPublishingPackage(
  context: SemanticContext,
  pubLib: (typeof PACKAGE)[keyof typeof PACKAGE],
): Promise<void> {
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
    const diffs =
      pubLib === PACKAGE.ROUTES_PACKAGE_NAME
        ? {
            name: PACKAGE.ROUTES_PACKAGE_NAME,
            ...defaults,
            files: [
              'dist',
              'src',
              'deployAddresses.json',
              'deployAddresses.csv',
              'deployBytecode.json',
              '!src/abi',
              '!src/utils',
              '!src/index.ts',
            ],
          }
        : {
            name: PACKAGE.ROUTES_TS_PACKAGE_NAME,
            ...defaults,
            files: [
              'dist',
              'deployAddresses.json',
              'deployAddresses.csv',
              'deployBytecode.json',
            ],
            dependencies: { viem: projectPackageJson.dependencies.viem },
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
    delete projectPackageJson.engines
    delete projectPackageJson.packageManager

    // Write the modified package.json
    fs.writeFileSync(
      packageJsonPath,
      JSON.stringify(projectPackageJson, null, 2),
    )
    logger.log('Created package.json for the build')
  }
}
