import Prover from '../../../artifacts/contracts/prover/Prover.sol/Prover.json'
import IntentSource from '../../../artifacts/contracts/IntentSource.sol/IntentSource.json'
import Inbox from '../../../artifacts/contracts/Inbox.sol/Inbox.json'
import HyperProver from '../../../artifacts/contracts/prover/HyperProver.sol/HyperProver.json'
import { MainnetChainConfigs } from '../../configs/chain.config'
import { Hex } from 'viem'

export type ContractDeployConfigs = {
  name: string
  path: string
  abi: any
  bytecode: Hex
  args: any[]
}

export type ContractNames = 'Prover' | 'IntentSource' | 'Inbox' | 'HyperProver'
const MainnetContracts: Record<ContractNames, ContractDeployConfigs> = {
  Prover: {
    name: Prover.contractName,
    path: 'contracts/prover',
    abi: Prover.abi,
    bytecode: Prover.bytecode as Hex,
    args: [
      5,
      [
        MainnetChainConfigs.baseChainConfiguration,
        MainnetChainConfigs.optimismChainConfiguration,
        MainnetChainConfigs.arbitrumChainConfiguration,
        MainnetChainConfigs.mantleChainConfiguration,
      ],
    ],
  },
  IntentSource: {
    name: IntentSource.contractName,
    path: 'contracts',
    abi: IntentSource.abi,
    bytecode: IntentSource.bytecode as Hex,
    args: [],
  },
  Inbox: {
    name: Inbox.contractName,
    path: 'contracts',
    abi: Inbox.abi,
    bytecode: Inbox.bytecode as Hex,
    args: [],
  },
  HyperProver: {
    name: HyperProver.contractName,
    path: 'contracts/prover',
    abi: HyperProver.abi,
    bytecode: HyperProver.bytecode as Hex,
    args: [],
  },
}
export default MainnetContracts
