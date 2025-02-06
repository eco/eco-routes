import {
  optimism,
  optimismSepolia,
  base,
  baseSepolia,
  arbitrum,
} from '@alchemy/aa-core'
import { Chain, mantle, polygon, polygonAmoy } from 'viem/chains'

// Mainnet chains
export const mainnetDep: Chain[] = [
  arbitrum,
  base,
  mantle,
  optimism,
  polygon,
  // mainnet,
  // abstract,
] as any

// Test chains
export const sepoliaDep: Chain[] = [
  // arbitrumSepolia,
  baseSepolia,
  // mantleSepoliaTestnet,
  optimismSepolia,
  polygonAmoy,
  // abstractTestnet
] as any

/**
 * The chains to deploy from {@link ProtocolDeploy}
 */
export const DeployChains = [mainnetDep].flat() as Chain[]
// export const DeployChains = [sepoliaDep, mainnetDep].flat() as Chain[]
