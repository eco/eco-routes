import { keccak256, solidityPacked, randomBytes, hexlify } from 'ethers';

/**
 * ERC2470 SingletonFactory address used in the Deploy.sol script
 */
const SINGLETON_FACTORY_ADDRESS = '0xce0042B868300000d44A59004Da54A005ffdcf9f';

/**
 * Interface for vanity address search options
 */
interface VanityOptions {
  /** The desired prefix for the contract address (without 0x) */
  prefix: string;
  /** The bytecode of the contract to deploy */
  bytecode: string;
  /** Maximum number of iterations to try (default: 1000000) */
  maxIterations?: number;
  /** Whether to search case-insensitive (default: true) */
  caseInsensitive?: boolean;
  /** Optional starting salt (as hex string) */
  startingSalt?: string;
}

/**
 * Result of vanity address search
 */
interface VanityResult {
  /** The salt that produces the desired address */
  salt: string;
  /** The predicted contract address */
  address: string;
  /** Number of iterations it took to find */
  iterations: number;
  /** Time taken in milliseconds */
  timeMs: number;
}

/**
 * Predicts the CREATE2 address for given factory, salt, and bytecode
 * Follows the same logic as predictCreate2Address in Deploy.sol
 */
function predictCreate2Address(
  factoryAddress: string,
  salt: string,
  bytecode: string
): string {
  const bytecodeHash = keccak256(bytecode);

  const create2Hash = keccak256(
    solidityPacked(
      ['bytes1', 'address', 'bytes32', 'bytes32'],
      ['0xff', factoryAddress, salt, bytecodeHash]
    )
  );

  // Take the last 20 bytes and convert to address
  return '0x' + create2Hash.slice(-40);
}

/**
 * Generates a random 32-byte salt
 */
function generateRandomSalt(): string {
  return hexlify(randomBytes(32));
}

/**
 * Increments a salt by 1
 */
function incrementSalt(salt: string): string {
  const saltBigInt = BigInt(salt);
  const incremented = saltBigInt + 1n;
  return '0x' + incremented.toString(16).padStart(64, '0');
}

/**
 * Brute forces different salts to find a vanity address with the desired prefix
 * Uses the ERC2470 SingletonFactory for address prediction
 */
export async function findVanityAddress(options: VanityOptions): Promise<VanityResult> {
  const {
    prefix,
    bytecode,
    maxIterations = 1000000,
    caseInsensitive = true,
    startingSalt
  } = options;

  // Normalize prefix
  const normalizedPrefix = caseInsensitive ? prefix.toLowerCase() : prefix;
  if (normalizedPrefix.startsWith('0x')) {
    throw new Error('Prefix should not include 0x');
  }

  console.log(`🔍 Searching for vanity address with prefix: ${normalizedPrefix}`);
  console.log(`📊 Max iterations: ${maxIterations.toLocaleString()}`);
  console.log(`🏭 Factory: ${SINGLETON_FACTORY_ADDRESS}`);

  const startTime = Date.now();
  let currentSalt = startingSalt || generateRandomSalt();

  for (let i = 0; i < maxIterations; i++) {
    const predictedAddress = predictCreate2Address(
      SINGLETON_FACTORY_ADDRESS,
      currentSalt,
      bytecode
    );

    // Remove 0x and check prefix
    const addressSuffix = predictedAddress.slice(2);
    const addressToCheck = caseInsensitive ? addressSuffix.toLowerCase() : addressSuffix;

    if (addressToCheck.startsWith(normalizedPrefix)) {
      const timeMs = Date.now() - startTime;

      console.log(`✅ Found vanity address!`);
      console.log(`🎯 Address: ${predictedAddress}`);
      console.log(`🧂 Salt: ${currentSalt}`);
      console.log(`🔄 Iterations: ${i + 1}`);
      console.log(`⏱️  Time: ${timeMs}ms`);

      return {
        salt: currentSalt,
        address: predictedAddress,
        iterations: i + 1,
        timeMs
      };
    }

    // Progress logging every 10,000 iterations
    if ((i + 1) % 10000 === 0) {
      const elapsed = Date.now() - startTime;
      const rate = (i + 1) / (elapsed / 1000);
      console.log(`⏳ Checked ${(i + 1).toLocaleString()} addresses (${rate.toFixed(0)} addr/sec)`);
    }

    // Increment salt for next iteration
    currentSalt = incrementSalt(currentSalt);
  }

  throw new Error(`Could not find vanity address with prefix "${prefix}" within ${maxIterations} iterations`);
}

/**
 * Estimates the expected number of iterations needed for a given prefix length
 */
export function estimateIterations(prefixLength: number, caseInsensitive: boolean = true): number {
  const base = caseInsensitive ? 16 : 16; // Hex is always base 16
  return Math.pow(base, prefixLength);
}

/**
 * Validates that the given salt produces the expected address
 */
export function validateVanityAddress(
  salt: string,
  bytecode: string,
  expectedAddress: string
): boolean {
  const predictedAddress = predictCreate2Address(
    SINGLETON_FACTORY_ADDRESS,
    salt,
    bytecode
  );

  return predictedAddress.toLowerCase() === expectedAddress.toLowerCase();
}

/**
 * CLI-style function for interactive use
 */
export async function searchVanityAddress(
  prefix: string,
  bytecode: string,
  maxIterations?: number
): Promise<void> {
  try {
    const estimated = estimateIterations(prefix.length, true);
    console.log(`📈 Estimated iterations needed: ~${estimated.toLocaleString()}`);

    if (estimated > 1000000 && !maxIterations) {
      console.log(`⚠️  Warning: This might take a very long time. Consider a shorter prefix.`);
    }

    const result = await findVanityAddress({
      prefix,
      bytecode,
      maxIterations
    });

    console.log(`\n🎉 Success! Use this salt in your deployment:`);
    console.log(`SALT=${result.salt}`);

  } catch (error) {
    console.error(`❌ Error:`, error);
    process.exit(1);
  }
}

// Example usage if run directly
if (require.main === module) {
  const args = process.argv.slice(2);
  if (args.length < 2) {
    console.log(`Usage: npx ts-node scripts/utils/vanity.ts <prefix> <bytecode> [maxIterations]`);
    console.log(`Example: npx ts-node scripts/utils/vanity.ts "eco" "0x608060405234801561001057600080fd5b50..."`);
    process.exit(1);
  }

  const [prefix, bytecode, maxIter] = args;
  const maxIterations = maxIter ? parseInt(maxIter) : undefined;

  searchVanityAddress(prefix, bytecode, maxIterations);
}