import * as pacote from 'pacote';
import * as fs from 'fs';
import * as path from 'path';
import { execSync } from 'child_process';
import * as os from 'os';
import { keccak256, toHex } from 'viem';

// Define a logger interface to make it consistent with semantic-release logger
export interface Logger {
  log: (message: string) => void;
  error: (message: string) => void;
  warn?: (message: string) => void;
}

/**
 * Retrieves the salt used for deployment from a previously published package version
 * @param packageName The npm package name to fetch
 * @param version The version being released (to determine major.minor)
 * @returns The salt string used for deployment
 */
export async function getSaltFromPackageVersion(packageName: string, version: string): Promise<string> {
  // Extract the major.minor from the version
  const [major, minor] = version.split('.');
  const versionBase = `${major}.${minor}`;
  
  console.log(`Finding last published version with base ${versionBase}.x`);
  
  try {
    // Get the last published version with the same major.minor
    const manifest = await pacote.manifest(`${packageName}@${versionBase}.x`);
    const lastVersion = manifest.version;
    
    console.log(`Found version ${lastVersion}, downloading package...`);
    
    // Create temp directory for extraction
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'eco-routes-'));
    
    // Download and extract the package
    await pacote.extract(`${packageName}@${lastVersion}`, tempDir);
    
    // Read deployment data to get salt
    const deployDataPath = path.join(tempDir, 'build', 'deployAddresses.json');
    
    if (!fs.existsSync(deployDataPath)) {
      throw new Error(`No deployment data found in package ${packageName}@${lastVersion}`);
    }
    
    // Load deployment info to extract salt info
    // This assumes the salt is calculated from the major.minor version
    // So we can recalculate it rather than find it directly
    const rootSalt = keccak256(toHex(versionBase));
    
    console.log(`Extracted salt for version ${versionBase}: ${rootSalt}`);
    
    // Clean up
    fs.rmSync(tempDir, { recursive: true, force: true });
    
    return rootSalt;
  } catch (error) {
    console.error(`Error extracting salt: ${(error as Error).message}`);
    throw error;
  }
}

/**
 * Determine salts for deployment based on version
 * @param version The full semantic version string (e.g. "1.2.3")
 * @param packageName The npm package name
 * @param logger Logger interface for output
 * @returns Object containing production and pre-production salts
 */
export async function determineSalts(
  version: string,
  packageName: string,
  logger: Logger
): Promise<{ rootSalt: string; preprodRootSalt: string }> {
  // Extract version components
  const [major, minor, patch] = version.split('.');
  const versionBase = `${major}.${minor}`;
  
  let rootSalt: string;
  let preprodRootSalt: string;
  
  try {
    // For patch versions, fetch previous package to get salt
    if (parseInt(patch) > 0) {
      logger.log(`Patch version detected (${patch}), fetching previous version for salt reuse`);
      
      // Get salt from previously published package
      rootSalt = await getSaltFromPackageVersion(packageName, version);
      preprodRootSalt = keccak256(toHex(`${versionBase}-preprod`));
    } else {
      const a = versionBase + 'asdfasdfasd3333'
      // New major/minor version - calculate fresh salt
      logger.log(`New major/minor version (${a}), calculating new salt`);
      rootSalt = keccak256(toHex(a));
      preprodRootSalt = keccak256(toHex(`${a}-preprod`));
    }
    
    logger.log(`Using salt for production: ${rootSalt}`);
    logger.log(`Using salt for pre-production: ${preprodRootSalt}`);
    
    return { rootSalt, preprodRootSalt };
  } catch (error) {
    logger.error(`Error determining salts: ${(error as Error).message}`);
    throw error;
  }
}