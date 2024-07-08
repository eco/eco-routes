import config from '../config/config'
import {
  AbiCoder,
  BigNumberish,
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
  ERC20__factory,
} from '../typechain-types'
import * as L2OutputArtifact from '@eth-optimism/contracts-bedrock/forge-artifacts/L2OutputOracle.sol/L2OutputOracle.json'
import * as L2ToL1MessagePasser from '@eth-optimism/contracts-bedrock/forge-artifacts/L2ToL1MessagePasser.sol/L2ToL1MessagePasser.json'
export namespace s {
  // default AbiCoder
  export const abiCoder = AbiCoder.defaultAbiCoder()
  // Private Keys
  export const DEPLOY_PRIVATE_KEY = process.env.DEPLOY_PRIVATE_KEY || ''
  export const INTENT_CREATOR_PRIVATE_KEY =
    process.env.INTENT_CREATOR_PRIVATE_KEY || ''
  export const SOLVER_PRIVATE_KEY = process.env.SOLVER_PRIVATE_KEY || ''
  export const CLAIMANT_PRIVATE_KEY = process.env.CLAIMANT_PRIVATE_KEY || ''
  export const PROVER_PRIVATE_KEY = process.env.PROVER_PRIVATE_KEY || ''
  export const ALCHEMY_API_KEY = process.env.ALCHEMY_API_KEY || ''

  // Providers
  export const layer1Provider = new AlchemyProvider(
    config.mainnet.network,
    ALCHEMY_API_KEY,
  )
  export const layer2SourceProvider = new AlchemyProvider(
    config.optimism.network,
    ALCHEMY_API_KEY,
  )
  export const layer2DestinationProvider = new AlchemyProvider(
    config.base.network,
    ALCHEMY_API_KEY,
  )

  // Signers
  // Layer2 Source
  export const layer2SourceIntentCreator: Signer = new Wallet(
    INTENT_CREATOR_PRIVATE_KEY,
    layer2SourceProvider,
  )
  export const layer2SourceIntentProver: Signer = new Wallet(
    PROVER_PRIVATE_KEY,
    layer2SourceProvider,
  )
  export const layer2SourceSolver: Signer = new Wallet(
    SOLVER_PRIVATE_KEY,
    layer2SourceProvider,
  )
  export const layer2SourceClaimant: Signer = new Wallet(
    CLAIMANT_PRIVATE_KEY,
    layer2SourceProvider,
  )
  // Layer2 Destination
  export const layer2DestinationSolver: Signer = new Wallet(
    SOLVER_PRIVATE_KEY,
    layer2DestinationProvider,
  )
  export const layer2DestinationProver: Signer = new Wallet(
    PROVER_PRIVATE_KEY,
    layer2DestinationProvider,
  )
  // Contracts
  // Note: we use providers for all System Contracts and Signers for Intent Protocol Contracts
  // Layer 1 mainnet
  export const layer1Layer2DestinationOutputOracleContract = new Contract(
    config.mainnet.l2BaseOutputOracleAddress,
    L2OutputArtifact.abi,
    layer1Provider,
  )
  // Layer 2 Source mainnet Optimism
  export const layer2Layer1BlockAddressContract = new Contract(
    config.optimism.l1BlockAddress,
    IL1Block__factory.abi,
    layer2SourceProvider,
  )
  export const layer2SourceIntentSourceContract = new Contract(
    config.optimism.intentSourceAddress,
    IntentSource__factory.abi,
    layer2SourceIntentCreator,
  )
  export const layer2SourceIntentSourceContractClaimant = new Contract(
    config.optimism.intentSourceAddress,
    IntentSource__factory.abi,
    layer2SourceClaimant,
  )
  export const layer2SourceProverContract = new Contract(
    config.optimism.proverContractAddress,
    Prover__factory.abi,
    layer2SourceIntentProver,
  )
  export const layer2SourceUSDCContract = new Contract(
    config.optimism.usdcAddress,
    ERC20__factory.abi,
    layer2SourceIntentCreator,
  )

  // Layer 2 Destination mainnet Base
  export const layer2DestinationInboxContract = new Contract(
    config.base.inboxAddress,
    Inbox__factory.abi,
    layer2DestinationSolver,
  )
  export const Layer2DestinationMessagePasserContract = new Contract(
    config.base.l2l1MessageParserAddress,
    L2ToL1MessagePasser.abi,
    layer2DestinationProvider,
  )
  export const layer2DestinationUSDCContract = new Contract(
    config.base.usdcAddress,
    ERC20__factory.abi,
    layer2DestinationSolver,
  )

  // const rewardToken: ERC20 = ERC20__factory.connect(rewardTokens[0], creator)

  // Intent Parameters
  export const intentCreator = config.mainnetIntent.creator
  export const intentSourceAddress = config.optimism.intentSourceAddress
  export const intentRewardAmounts = config.mainnetIntent.rewardAmounts
  export const intentRewardTokens = config.mainnetIntent.rewardTokens
  export const intentDestinationChainId: BigNumberish =
    config.mainnetIntent.destinationChainId
  export const intentTargetTokens = config.mainnetIntent.targetTokens
  export const intentTargetAmounts = config.mainnetIntent.targetAmounts
  export const intentRecipient = config.mainnetIntent.recipient
  export const intentDuration = config.mainnetIntent.duration
}
