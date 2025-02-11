import { network } from 'hardhat'
import {
  DeployNetwork,
  deployProtocol,
  getEmptyProtocolDeploy,
  ProtocolDeploy,
} from '../deloyProtocol'
import { actors } from '../../config/mainnet/config'
import { MainnetChainConfigs } from '../configs/chain.config'
import { getDeployNetwork } from '../utils'

const protocolDeploy: ProtocolDeploy = getEmptyProtocolDeploy()

deployProtocol(
  protocolDeploy,
  getDeployNetwork(network.name) as DeployNetwork,
  actors.solver,
  [
    MainnetChainConfigs.baseChainConfiguration,
    MainnetChainConfigs.optimismChainConfiguration,
    // MainnetChainConfigs.helixChainConfiguration,
    MainnetChainConfigs.arbitrumChainConfiguration,
    MainnetChainConfigs.mantleChainConfiguration,
    MainnetChainConfigs.curtisTestnetChainConfiguration,
  ],
  { isSolvingPublic: true, deployPre: true },
).catch((error) => {
  console.error(error)
  process.exitCode = 1
})
