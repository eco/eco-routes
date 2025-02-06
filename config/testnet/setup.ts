import {
  getDefaultProvider,
  AbiCoder,
  AlchemyProvider,
  Contract,
  Wallet,
  Signer,
} from 'ethers'
import {
  Inbox__factory,
  IntentSource__factory,
  IL1Block__factory,
  Prover__factory,
  //   ProverL3__factory,
  ERC20__factory,
} from '../../typechain-types'
import { networks } from '../../config/testnet/config'
import * as L2OutputArtifact from '@eth-optimism/contracts-bedrock/forge-artifacts/L2OutputOracle.sol/L2OutputOracle.json'
import * as DisputeGameFactoryArtifact from '@eth-optimism/contracts-bedrock/forge-artifacts/DisputeGameFactory.sol/DisputeGameFactory.json'
import * as L2ToL1MessagePasserArtifact from '@eth-optimism/contracts-bedrock/forge-artifacts/L2ToL1MessagePasser.sol/L2ToL1MessagePasser.json'
export namespace s {
  // default AbiCoder
  export const abiCoder = AbiCoder.defaultAbiCoder()
  // Private Keys
  export const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY || ''
  export const INTENT_CREATOR_PRIVATE_KEY =
    process.env.INTENT_CREATOR_PRIVATE_KEY || ''
  export const SOLVER_PRIVATE_KEY = process.env.SOLVER_PRIVATE_KEY || ''
  export const CLAIMANT_PRIVATE_KEY = process.env.CLAIMANT_PRIVATE_KEY || ''
  export const PROVER_PRIVATE_KEY = process.env.PROVER_PRIVATE_KEY || ''
  export const ALCHEMY_API_KEY = process.env.ALCHEMY_API_KEY || ''

  // The following setup is Per Chain
  // Sepolia
  // Providers
  export const sepoliaProvider = new AlchemyProvider(
    networks.sepolia.network,
    ALCHEMY_API_KEY,
  )
  // Signers
  export const sepoliaDeployer: Signer = new Wallet(
    DEPLOYER_PRIVATE_KEY,
    sepoliaProvider,
  )
  export const sepoliaIntentCreator: Signer = new Wallet(
    INTENT_CREATOR_PRIVATE_KEY,
    sepoliaProvider,
  )
  export const sepoliaSolver: Signer = new Wallet(
    SOLVER_PRIVATE_KEY,
    sepoliaProvider,
  )
  export const sepoliaIntentProver: Signer = new Wallet(
    PROVER_PRIVATE_KEY,
    sepoliaProvider,
  )
  export const sepoliaClaimant: Signer = new Wallet(
    CLAIMANT_PRIVATE_KEY,
    sepoliaProvider,
  )
  // Contracts
  // Note: we use providers for all System Contracts and Signers for Intent Protocol Contracts
  // Settlement Contracts for other Chains
  export const sepoliaSettlementContractBase = new Contract(
    networks.sepolia.settlementContracts.baseSepolia,
    DisputeGameFactoryArtifact.abi,
    sepoliaProvider,
  )
  export const sepoliaSettlementContractOptimism = new Contract(
    networks.sepolia.settlementContracts.optimismSepolia,
    DisputeGameFactoryArtifact.abi,
    sepoliaProvider,
  )
  // System Proving Contracts
  // ECO PROTOCOL Contracts

  // OpstimismSepolia
  // Providers
  export const optimismSepoliaProvider = new AlchemyProvider(
    networks.optimismSepolia.network,
    ALCHEMY_API_KEY,
  )
  // Signers
  export const optimismSepoliaDeployer: Signer = new Wallet(
    DEPLOYER_PRIVATE_KEY,
    optimismSepoliaProvider,
  )
  export const optimismSepoliaIntentCreator: Signer = new Wallet(
    INTENT_CREATOR_PRIVATE_KEY,
    optimismSepoliaProvider,
  )
  export const optimismSepoliaSolver: Signer = new Wallet(
    SOLVER_PRIVATE_KEY,
    optimismSepoliaProvider,
  )
  export const optimismSepoliaIntentProver: Signer = new Wallet(
    PROVER_PRIVATE_KEY,
    optimismSepoliaProvider,
  )
  export const optimismSepoliaClaimant: Signer = new Wallet(
    CLAIMANT_PRIVATE_KEY,
    optimismSepoliaProvider,
  )
  // Contracts
  // Settlement Contracts for other Chains
  // System Proving Contracts
  export const optimismSepolial1Block = new Contract(
    networks.optimismSepolia.proving.l1BlockAddress,
    IL1Block__factory.abi,
    optimismSepoliaProvider,
  )
  export const optimismSepoliaL2L1MessageParserContract = new Contract(
    networks.optimismSepolia.proving.l2l1MessageParserAddress,
    L2ToL1MessagePasserArtifact.abi,
    optimismSepoliaProvider,
  )

  // ECO PROTOCOL Contracts
  export const optimismSepoliaIntentSourceContractIntentCreator = new Contract(
    networks.optimismSepolia.intentSourceAddress,
    IntentSource__factory.abi,
    optimismSepoliaIntentCreator,
  )
  export const optimismSepoliaIntentSourceContractClaimant = new Contract(
    networks.optimismSepolia.intentSourceAddress,
    IntentSource__factory.abi,
    optimismSepoliaClaimant,
  )
  export const optimismSepoliaProverContract = new Contract(
    networks.optimismSepolia.proverContractAddress,
    Prover__factory.abi,
    optimismSepoliaIntentProver,
  )
  export const optimismSepoliaInboxContractSolver = new Contract(
    networks.optimismSepolia.inboxAddress,
    Inbox__factory.abi,
    optimismSepoliaSolver,
  )
  export const optimismSepoliaUSDCContractIntentCreator = new Contract(
    networks.optimismSepolia.usdcAddress,
    ERC20__factory.abi,
    optimismSepoliaIntentCreator,
  )
  export const optimismSepoliaUSDCContractSolver = new Contract(
    networks.optimismSepolia.usdcAddress,
    ERC20__factory.abi,
    optimismSepoliaSolver,
  )
  // BaseSepolia
  // Providers
  export const baseSepoliaProvider = new AlchemyProvider(
    networks.baseSepolia.network,
    ALCHEMY_API_KEY,
  )
  // Signers
  export const baseSepoliaDeployer: Signer = new Wallet(
    DEPLOYER_PRIVATE_KEY,
    baseSepoliaProvider,
  )
  export const baseSepoliaIntentCreator: Signer = new Wallet(
    INTENT_CREATOR_PRIVATE_KEY,
    baseSepoliaProvider,
  )
  export const baseSepoliaSolver: Signer = new Wallet(
    SOLVER_PRIVATE_KEY,
    baseSepoliaProvider,
  )
  export const baseSepoliaIntentProver: Signer = new Wallet(
    PROVER_PRIVATE_KEY,
    baseSepoliaProvider,
  )
  export const baseSepoliaClaimant: Signer = new Wallet(
    CLAIMANT_PRIVATE_KEY,
    baseSepoliaProvider,
  )
  // Contracts
  // Settlement Contracts for other Chains
  export const baseSepoliaSettlementContractEcoTestNet = new Contract(
    networks.baseSepolia.settlementContracts.ecoTestnet,
    L2OutputArtifact.abi,
    baseSepoliaProvider,
  )
  // System Proving Contracts
  export const baseSepolial1Block = new Contract(
    networks.baseSepolia.proving.l1BlockAddress,
    IL1Block__factory.abi,
    baseSepoliaProvider,
  )
  export const baseSepoliaL2L1MessageParserContract = new Contract(
    networks.baseSepolia.proving.l2l1MessageParserAddress,
    L2ToL1MessagePasserArtifact.abi,
    baseSepoliaProvider,
  )
  // ECO PROTOCOL Contracts
  export const baseSepoliaIntentSourceContractIntentCreator = new Contract(
    networks.baseSepolia.intentSourceAddress,
    IntentSource__factory.abi,
    baseSepoliaIntentCreator,
  )
  export const baseSepoliaIntentSourceContractClaimant = new Contract(
    networks.baseSepolia.intentSourceAddress,
    IntentSource__factory.abi,
    baseSepoliaClaimant,
  )

  export const baseSepoliaProverContract = new Contract(
    networks.baseSepolia.proverContractAddress,
    Prover__factory.abi,
    baseSepoliaIntentProver,
  )
  export const baseSepoliaInboxContractSolver = new Contract(
    networks.baseSepolia.inboxAddress,
    Inbox__factory.abi,
    baseSepoliaSolver,
  )
  export const baseSepoliaUSDCContractIntentCreator = new Contract(
    networks.baseSepolia.usdcAddress,
    ERC20__factory.abi,
    baseSepoliaIntentCreator,
  )
  export const baseSepoliaUSDCContractSolver = new Contract(
    networks.baseSepolia.usdcAddress,
    ERC20__factory.abi,
    baseSepoliaSolver,
  )

  // EcoTestNet
  // Providers
  export const ecoTestnetProvider = getDefaultProvider(
    networks.ecoTestnet.rpcUrl,
  )
  // Signers
  export const ecoTestnetDeployer: Signer = new Wallet(
    DEPLOYER_PRIVATE_KEY,
    ecoTestnetProvider,
  )
  export const ecoTestnetIntentCreator: Signer = new Wallet(
    INTENT_CREATOR_PRIVATE_KEY,
    ecoTestnetProvider,
  )
  export const ecoTestnetSolver: Signer = new Wallet(
    SOLVER_PRIVATE_KEY,
    ecoTestnetProvider,
  )
  export const ecoTestnetIntentProver: Signer = new Wallet(
    PROVER_PRIVATE_KEY,
    ecoTestnetProvider,
  )
  export const ecoTestnetClaimant: Signer = new Wallet(
    CLAIMANT_PRIVATE_KEY,
    ecoTestnetProvider,
  )
  // Contracts
  // Settlement Contracts for other Chains

  // System Proving Contracts
  export const ecoTestnetl1Block = new Contract(
    networks.ecoTestnet.proving.l1BlockAddress,
    IL1Block__factory.abi,
    ecoTestnetProvider,
  )
  export const ecoTestnetL2L1MessageParserContract = new Contract(
    networks.ecoTestnet.proving.l2l1MessageParserAddress,
    L2ToL1MessagePasserArtifact.abi,
    ecoTestnetProvider,
  )
  // ECO PROTOCOL Contracts
  export const ecoTestnetIntentSourceContractIntentCreator = new Contract(
    networks.ecoTestnet.intentSourceAddress,
    IntentSource__factory.abi,
    ecoTestnetIntentCreator,
  )

  export const ecoTestnetIntentSourceContractClaimant = new Contract(
    networks.ecoTestnet.intentSourceAddress,
    IntentSource__factory.abi,
    ecoTestnetClaimant,
  )
  //   export const ecoTestnetProverContract = new Contract(
  //     networks.ecoTestnet.proverContractAddress,
  //     ProverL3__factory.abi,
  //     ecoTestnetDeployer, // Use deployer as prover as we need to do privileged operations
  //   )
  export const ecoTestnetInboxContractSolver = new Contract(
    networks.ecoTestnet.inboxAddress,
    Inbox__factory.abi,
    ecoTestnetSolver,
  )
  export const ecoTestnetUSDCContractIntentCreator = new Contract(
    networks.ecoTestnet.usdcAddress,
    ERC20__factory.abi,
    ecoTestnetIntentCreator,
  )
  export const ecoTestnetUSDCContractSolver = new Contract(
    networks.ecoTestnet.usdcAddress,
    ERC20__factory.abi,
    ecoTestnetSolver,
  )
}
