import {
  optimism,
  optimismSepolia,
  base,
  baseSepolia,
  arbitrum,
} from '@alchemy/aa-core'
import { Chain, mainnet, mantle, polygon, sepolia } from 'viem/chains'

// Mainnet chains
export const mainnetDep: Chain[] = [
  arbitrum,
  base,
  mantle,
  optimism,
  polygon,
  mainnet,
  // abstract,
] as any

// Test chains
export const sepoliaDep: Chain[] = [
  // problamatic
  // arbitrumSepolia,
  // mantleSepoliaTestnet,
  // abstractTestnet,
  // working
  baseSepolia,
  optimismSepolia,
  sepolia,
] as any

/**
 * The chains to deploy from {@link ProtocolDeploy}
 * Deployer 0xB963326B9969f841361E6B6605d7304f40f6b414
 */
// export const DeployChains = [mainnetDep].flat() as Chain[]
export const DeployChains = [sepoliaDep, mainnetDep].flat() as Chain[]
