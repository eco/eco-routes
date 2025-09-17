import axios from 'axios'
import { Logger } from '../semantic-release/helpers'

interface ChainConfig {
  url: string
  mailbox?: string
  router?: string
  crossL2proverV2?: string // This is the key field we're looking for
  metaProver?: boolean
  legacy?: boolean
  gasMultiplier?: string
}

interface ChainData {
  chainId: number
  rpcUrl: string
  hasPolymerProver: boolean
  crossL2proverV2?: string
}

/**
 * Fetches chain data from CHAIN_DATA_URL and filters for chains with crossL2proverV2
 * @param chainDataUrl - URL to fetch chain configuration data from
 * @param logger - Logger instance for output
 * @returns Array of chain data for chains that have crossL2proverV2 configured
 */
export async function fetchChainData(
  chainDataUrl: string,
  logger: Logger,
): Promise<ChainData[]> {
  try {
    logger.log(`📡 Fetching chain data from: ${chainDataUrl}`)
    const response = await axios.get(chainDataUrl)
    const data: Record<string, ChainConfig> = response.data

    const chains: ChainData[] = []
    for (const [chainId, config] of Object.entries(data)) {
      // Only include chains with crossL2proverV2 configured
      if (config.crossL2proverV2) {
        chains.push({
          chainId: parseInt(chainId),
          rpcUrl: config.url,
          hasPolymerProver: true,
          crossL2proverV2: config.crossL2proverV2,
        })
      }
    }

    logger.log(
      `✅ Found ${chains.length} chains with Polymer Prover configuration (crossL2proverV2 field)`,
    )
    logger.log(`📊 Chain IDs: ${chains.map((c) => c.chainId).join(', ')}`)
    return chains
  } catch (error) {
    logger.error(`❌ Failed to fetch chain data: ${(error as Error).message}`)
    return []
  }
}

/**
 * Gets target chain IDs for address prediction - chains with crossL2proverV2 field
 * @param chainDataUrl - URL to fetch chain configuration data from
 * @param logger - Logger instance for output
 * @returns Array of chain IDs that need Polymer Prover address prediction
 */
export async function getTargetChainIds(
  chainDataUrl: string,
  logger: Logger,
): Promise<number[]> {
  const chains = await fetchChainData(chainDataUrl, logger)
  return chains.map((c) => c.chainId)
}

/**
 * Validates that the chain data URL is accessible and returns valid data
 * @param chainDataUrl - URL to validate
 * @param logger - Logger instance for output
 * @returns Boolean indicating if URL is valid and accessible
 */
export async function validateChainDataUrl(
  chainDataUrl: string,
  logger: Logger,
): Promise<boolean> {
  try {
    const response = await axios.get(chainDataUrl)
    const data = response.data

    // Check if response is a valid object
    if (!data || typeof data !== 'object') {
      logger.error('❌ Chain data URL returned invalid data format')
      return false
    }

    // Check if at least one chain has the required structure
    const hasValidChain = Object.values(data).some(
      (config: any) => config && typeof config === 'object' && config.url,
    )

    if (!hasValidChain) {
      logger.error('❌ Chain data does not contain valid chain configurations')
      return false
    }

    logger.log('✅ Chain data URL is valid and accessible')
    return true
  } catch (error) {
    logger.error(
      `❌ Chain data URL validation failed: ${(error as Error).message}`,
    )
    return false
  }
}
