import { networks } from '../../config/mainnet/config'
import { DeployNetworkConfig } from '../deloyProtocol'

export const baseChainConfiguration: DeployNetworkConfig = {
  chainId: networks.base.chainId, // chainId
  chainConfiguration: {
    provingMechanism: networks.base.proving.mechanism, // provingMechanism
    settlementChainId: networks.base.proving.settlementChain.id, // settlementChainId
    settlementContract: networks.base.proving.settlementChain.contract, // settlementContract e.g DisputGameFactory or L2OutputOracle.
    blockhashOracle: networks.base.proving.l1BlockAddress, // blockhashOracle
    outputRootVersionNumber: networks.base.proving.outputRootVersionNumber, // outputRootVersionNumber
    finalityDelaySeconds: 0,
  },
}

export const optimismChainConfiguration: DeployNetworkConfig = {
  chainId: networks.optimism.chainId, // chainId
  chainConfiguration: {
    provingMechanism: networks.optimism.proving.mechanism, // provingMechanism
    settlementChainId: networks.optimism.proving.settlementChain.id, // settlementChainId
    settlementContract: networks.optimism.proving.settlementChain.contract, // settlementContract e.g DisputGameFactory or L2OutputOracle.     blockhashOracle: networks.optimism.proving.l1BlockAddress,
    blockhashOracle: networks.optimism.proving.l1BlockAddress, // blockhashOracle
    outputRootVersionNumber: networks.optimism.proving.outputRootVersionNumber,
    finalityDelaySeconds: 0,
  },
}

export const helixChainConfiguration: DeployNetworkConfig = {
  chainId: networks.helix.chainId, // chainId
  chainConfiguration: {
    provingMechanism: networks.helix.proving.mechanism, // provingMechanism
    settlementChainId: networks.helix.proving.settlementChain.id, // settlementChainId
    settlementContract: networks.helix.proving.settlementChain.contract, // settlementContract e.g DisputGameFactory or L2OutputOracle.
    blockhashOracle: networks.helix.proving.l1BlockAddress, // blockhashOracle
    outputRootVersionNumber: networks.helix.proving.outputRootVersionNumber, // outputRootVersionNumber
    finalityDelaySeconds: 0,
  },
}

export const arbitrumChainConfiguration: DeployNetworkConfig = {
  chainId: networks.arbitrum.chainId, // chainId
  chainConfiguration: {
    provingMechanism: networks.arbitrum.proving.mechanism, // provingMechanism
    settlementChainId: networks.arbitrum.proving.settlementChain.id, // settlementChainId
    settlementContract: networks.arbitrum.proving.settlementChain.contract, // settlementContract e.g DisputGameFactory or L2OutputOracle.
    blockhashOracle: networks.arbitrum.proving.l1BlockAddress, // blockhashOracle
    outputRootVersionNumber: networks.arbitrum.proving.outputRootVersionNumber, // outputRootVersionNumber
    finalityDelaySeconds: 0,
  },
}

export const mantleChainConfiguration: DeployNetworkConfig = {
  chainId: networks.mantle.chainId, // chainId
  chainConfiguration: {
    provingMechanism: networks.mantle.proving.mechanism, // provingMechanism
    settlementChainId: networks.mantle.proving.settlementChain.id, // settlementChainId
    settlementContract: networks.mantle.proving.settlementChain.contract, // settlementContract e.g DisputGameFactory or L2OutputOracle.
    blockhashOracle: networks.mantle.proving.l1BlockAddress, // blockhashOracle
    outputRootVersionNumber: networks.mantle.proving.outputRootVersionNumber, // outputRootVersionNumber
    finalityDelaySeconds: 604800,
  },
}

export const curtisTestnetChainConfiguration: DeployNetworkConfig = {
  chainId: networks.curtisTestnet.chainId, // chainId
  chainConfiguration: {
    provingMechanism: networks.curtisTestnet.proving.mechanism, // provingMechanism
    settlementChainId: networks.curtisTestnet.proving.settlementChain.id, // settlementChainId
    settlementContract: networks.curtisTestnet.proving.settlementChain.contract, // settlementContract e.g DisputGameFactory or L2OutputOracle.
    blockhashOracle: networks.curtisTestnet.proving.l1BlockAddress, // blockhashOracle
    outputRootVersionNumber:
      networks.curtisTestnet.proving.outputRootVersionNumber, // outputRootVersionNumber
    finalityDelaySeconds: 0,
  },
}
