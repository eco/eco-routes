import path from 'path'

/**
 * @file constants.ts
 *
 * Central configuration for all semantic-release scripts and deployment processes.
 *
 * This file serves as the single source of truth for paths, environment variable names,
 * and other constants used throughout the release process. By centralizing these values,
 * we ensure consistency across different scripts and make maintenance simpler.
 *
 * The constants include:
 * - File paths for build artifacts and deployment results
 * - Environment variable names for configuration
 * - Required environment variables for different operations
 * - Package naming conventions
 * - Performance thresholds and limits
 *
 * These constants are used by the deployment, verification, and packaging scripts
 * to locate files, validate configurations, and ensure consistent behavior.
 */
export const PATHS = {
  // Build related paths
  BUILD_DIR: 'build',

  // Deployment related paths
  OUTPUT_DIR: 'out',
  DEPLOYMENT_RESULTS_FILE: 'deployed.csv',
  DEPLOYMENT_ALL_FILE: 'deployedAll.csv',
  DEPLOYMENT_BYTECODE_FILE: 'deployBytecode.json',
  DEPLOYED_ADDRESSES_JSON: 'build/deployAddresses.json',
  SINGLETON_FACTORY_DEPLOY_SCRIPT: 'scripts/deploySingletonFactory.sh',
  DEPLOY_SCRIPT: 'scripts/deployRoutes.sh',

  // Verification related paths
  VERIFICATION_SCRIPT: 'scripts/verifyRoutes.sh',
  VERIFICATION_KEYS_FILE: 'verification-keys.json',

  // Chains
  DEFAULT_CHAIN_DATA_URL:
    'https://raw.githubusercontent.com/eco/eco-chains/refs/heads/main/src/assets/chain.json',

  // Package related
  PACKAGE_JSON: 'package.json',
  README_FILE: 'README.md',
  LICENSE_FILE: 'LICENSE',
}

/**
 * Environment variable names used across semantic-release scripts
 * These are used for deployment credentials, verification keys, and controlling publishing behavior
 */
export const ENV_VARS = {
  // Deployment related
  PRIVATE_KEY: 'PRIVATE_KEY',
  ALCHEMY_API_KEY: 'ALCHEMY_API_KEY',
  HYPERPROVER_CREATEX_ADDRESS: 'HYPERPROVER_CREATEX_ADDRESS',
  HYPERPROVER_2470_ADDRESS: 'HYPERPROVER_2470_ADDRESS',
  HYPER_PROVER_SALT: 'HYPER_PROVER_SALT',
  POLYMER_PROVER_SALT: 'POLYMER_PROVER_SALT',
  SALT: 'SALT',
  SALT_OPTIONAL: 'SALT_OPTIONAL',
  APPEND_RESULTS: 'APPEND_RESULTS',
  RESULTS_FILE: 'RESULTS_FILE',

  // NPM related
  NPM_TOKEN: 'NPM_TOKEN',
  NOT_DRY_RUN: 'NOT_DRY_RUN',
  CI: 'CI',

  // Verification related
  VERIFICATION_KEY: 'VERIFICATION_KEY',
  // Verification keys file
  VERIFICATION_KEYS_FILE: 'VERIFICATION_KEYS_FILE',
}

/**
 * Environment variables that are required for deployment and verification
 */
export const ENV_VARS_REQUIRED = [
  ENV_VARS.PRIVATE_KEY,
  ENV_VARS.ALCHEMY_API_KEY,
  ENV_VARS.RESULTS_FILE,
]

/**
 * Package related constants including npm package names
 * Used to maintain consistent naming between JavaScript and Solidity components
 */
export const PACKAGE = {
  ROUTES_PACKAGE_NAME: '@eco-foundation/routes',
  ROUTES_TS_PACKAGE_NAME: '@eco-foundation/routes-ts',
}

/**
 * Threshold values and limits for various operations
 * Used to warn about potential performance or security issues
 */
export const THRESHOLDS = {
  // Number of verification entries that might cause performance concerns
  VERIFICATION_ENTRIES_WARNING: 20,
}

/**
 * Constructs an absolute path by joining the current working directory with a relative path.
 * This utility ensures all file operations use consistent, absolute paths regardless of where
 * the script is executed from.
 *
 * @param cwd - Current working directory as the base path
 * @param relativePath - Relative path to resolve against the base path
 * @returns Absolute path with normalized directory separators
 *
 * @example
 * // Get absolute path to the build directory
 * const buildDir = getAbsolutePath('/project/root', 'build');
 * // Result: '/project/root/build'
 */
export function getAbsolutePath(cwd: string, relativePath: string): string {
  return path.join(cwd, relativePath)
}

/**
 * Retrieves the absolute path to the deployment results CSV file, which contains
 * records of all contracts deployed during the current release process.
 *
 * This file is critical for tracking deployment results across multiple chains
 * and environments, and is used for verification, client library generation,
 * and deployment auditing.
 *
 * @param cwd - Current working directory as the base path
 * @returns Absolute path to the deployment results CSV file
 *
 * @example
 * // Get path to deployment results file
 * const resultsPath = getDeploymentResultsPath('/project/root');
 * // Result: '/project/root/out/deployed.csv'
 */
export function getDeploymentResultsPath(cwd: string): string {
  return getAbsolutePath(
    cwd,
    path.join(PATHS.OUTPUT_DIR, PATHS.DEPLOYMENT_RESULTS_FILE),
  )
}

/**
 * Retrieves the absolute path to the deployAddresses.json file, which is the primary
 * artifact containing all deployed contract addresses organized by chain ID and environment.
 *
 * This JSON file is included in the published npm package and used by client libraries
 * to locate the correct contract addresses for each chain and environment. It serves
 * as the single source of truth for contract addresses across the protocol's deployment.
 *
 * @param cwd - Current working directory as the base path
 * @returns Absolute path to the deployed addresses JSON file
 *
 * @example
 * // Get path to deployed addresses JSON file
 * const addressesPath = getDeployedAddressesJsonPath('/project/root');
 * // Result: '/project/root/build/deployAddresses.json'
 */
export function getDeployedAddressesJsonPath(cwd: string): string {
  return getAbsolutePath(cwd, PATHS.DEPLOYED_ADDRESSES_JSON)
}

/**
 * Retrieves the absolute path to the build directory, which contains all compiled
 * artifacts, deployment results, and package files prepared for publication.
 *
 * The build directory is a temporary workspace created during the release process
 * where all artifacts are collected, organized, and prepared before being published
 * to npm. This includes contract ABIs, addresses, TypeScript definitions, and more.
 *
 * @param cwd - Current working directory as the base path
 * @returns Absolute path to the build directory
 *
 * @example
 * // Get path to build directory
 * const buildDir = getBuildDirPath('/project/root');
 * // Result: '/project/root/build'
 */
export function getBuildDirPath(cwd: string): string {
  return getAbsolutePath(cwd, PATHS.BUILD_DIR)
}
