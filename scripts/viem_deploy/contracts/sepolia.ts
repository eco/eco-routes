import MainnetContracts, {
  ContractDeployConfigs,
  ContractNames,
} from './mainnet'

const SepoliaContracts: Record<ContractNames, ContractDeployConfigs> = {
  ...MainnetContracts,
  // Prover: {
  //   ...MainnetContracts.Prover,
  //   args: [
  //     5,
  //     [
  //       SepoliaChainConfigs.baseSepoliaChainConfiguration,
  //       SepoliaChainConfigs.optimismSepoliaChainConfiguration,
  //       SepoliaChainConfigs.arbitrumSepoliaChainConfiguration,
  //       SepoliaChainConfigs.mantleSepoliaChainConfiguration,
  //     ],
  //   ],
  // },
}
export default SepoliaContracts
