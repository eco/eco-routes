import {
  arbitrumChainConfiguration,
  baseChainConfiguration,
  curtisTestnetChainConfiguration,
  mantleChainConfiguration,
  optimismChainConfiguration,
} from './mainnet.config'
import {
  arbitrumSepoliaChainConfiguration,
  baseSepoliaChainConfiguration,
  mantleSepoliaChainConfiguration,
  optimismSepoliaChainConfiguration,
} from './sepolia.config'

export const SepoliaChainConfigs = {
  baseSepoliaChainConfiguration,
  optimismSepoliaChainConfiguration,
  // ecoTestnetChainConfiguration,
  arbitrumSepoliaChainConfiguration,
  mantleSepoliaChainConfiguration,
}

export const MainnetChainConfigs = {
  baseChainConfiguration,
  optimismChainConfiguration,
  // helixChainConfiguration,
  arbitrumChainConfiguration,
  mantleChainConfiguration,
  curtisTestnetChainConfiguration,
}
