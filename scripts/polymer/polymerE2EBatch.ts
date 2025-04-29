import dotenv from 'dotenv'
import axios from 'axios'
import { networks } from '../../config/testnet/config'
import { ethers } from 'ethers'
import { Call, TokenAmount, Route, Reward, Intent } from '../../utils/intent'
import {
  IntentSource,
  IntentSource__factory,
  Inbox,
  Inbox__factory,
  PolyNativeProver,
  PolyNativeProver__factory,
  TestERC20__factory,
} from '../../typechain-types'


interface ProofRequestParams {
  chainId: number
  blockNumber: number
  txIndex: number
  localLogIndex: number
}

async function main() {
  // Get network choice from command line arguments
  const args = process.argv.slice(2)
  let isTestnet = true

  if (args.length > 0) {
    if (args[0].toLowerCase() === 'mainnet') {
      isTestnet = false
    } else if (args[0].toLowerCase() !== 'testnet') {
      console.log(
        'Invalid network argument. Please specify "testnet" or "mainnet"',
      )
      process.exit(1)
    }
  } else {
    console.log('No network specified. Defaulting to testnet...')
  }

  // Load deployed contract addresses
  let deployedAddresses
  try {
    deployedAddresses = require('./deployed.json')
  } catch (error) {
    console.error('Error loading deployed.json. Please run deploy.sh first')
    process.exit(1)
  }

  // Verify network choice matches deployed contracts
  const expectedNetwork = isTestnet ? '1' : '2'
  if (deployedAddresses.network !== expectedNetwork) {
    console.error(
      `Network mismatch: Script running for ${isTestnet ? 'testnet' : 'mainnet'} but deployed.json is for ${deployedAddresses.network === '1' ? 'testnet' : 'mainnet'}`,
    )
    process.exit(1)
  }

  const op_explorer = 'https://optimistic.etherscan.io//tx/'
  const base_explorer = 'https://basescan.org/tx/'
  const op_testnet_explorer = 'https://sepolia-optimism.etherscan.io//tx/'
  const base_testnet_explorer = 'https://sepolia.basescan.org/tx/'

  const batchSize = 20
  const usdcAmount = Number(ethers.parseUnits('0.01', 6))
  const usdcRewardAmount = Number(ethers.parseUnits('0.0101', 6))

  /// network information ///
  dotenv.config()
  const network_info = {
    optimism: {
      inbox: deployedAddresses.optimism_inbox,
      prover: deployedAddresses.optimism_prover,
      chainId: isTestnet ? 11155420 : 10,
      intentSource: deployedAddresses.optimism_intent_source,
      usdc: isTestnet
        ? '0x5fd84259d66Cd46123540766Be93DFE6D43130D7'
        : '0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85',
      usdcDecimals: 6,
      usdcAmount: usdcAmount,
      usdcRewardAmount: usdcRewardAmount,
      explorer: isTestnet ? op_testnet_explorer : op_explorer,
    },
    base: {
      inbox: deployedAddresses.base_inbox,
      prover: deployedAddresses.base_prover,
      chainId: isTestnet ? 84532 : 8453,
      intentSource: deployedAddresses.base_intent_source,
      usdc: isTestnet
        ? '0x036CbD53842c5426634e7929541eC2318f3dCF7e'
        : '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
      usdcDecimals: 6,
      usdcAmount: usdcAmount,
      usdcRewardAmount: usdcRewardAmount,
      explorer: isTestnet ? base_testnet_explorer : base_explorer,
    },
  }

  /// bind providers ///

  const ALCHEMY_API_KEY = process.env.ALCHEMY_API_KEY
  if (!ALCHEMY_API_KEY) {
    throw new Error('ALCHEMY_API_KEY environment variable not found')
  }

  const privateKey = process.env.DEPLOYER_PRIVATE_KEY
  if (!privateKey) {
    throw new Error('DEPLOYER_PRIVATE_KEY environment variable not found')
  }

  const optimismProvider = new ethers.AlchemyProvider(
    network_info.optimism.chainId,
    ALCHEMY_API_KEY,
  )

  const optimismWallet = new ethers.Wallet(privateKey, optimismProvider)

  const baseProvider = new ethers.AlchemyProvider(
    network_info.base.chainId,
    ALCHEMY_API_KEY,
  )

  const baseWallet = new ethers.Wallet(privateKey, baseProvider)

  console.log('⛓️  connected to optimism and base...')
  /// bind the contracts on Optimism mainnet (IntentSource, Inbox, PolyNativeProver) ///

  const optimismIntentSource: IntentSource = IntentSource__factory.connect(
    network_info.optimism.intentSource,
    optimismWallet,
  )

  const optimismInbox: Inbox = Inbox__factory.connect(
    network_info.optimism.inbox,
    optimismWallet,
  )

  const optimismPolyNativeProver: PolyNativeProver = PolyNativeProver__factory.connect(
    network_info.optimism.prover,
    optimismWallet,
  )

  const optimismUSDC = TestERC20__factory.connect(
    network_info.optimism.usdc,
    optimismWallet,
  )

  const baseUSDC = TestERC20__factory.connect(
    network_info.base.usdc,
    baseWallet,
  )

  const baseIntentSource: IntentSource = IntentSource__factory.connect(
    network_info.base.intentSource,
    baseWallet,
  )

  const baseInbox: Inbox = Inbox__factory.connect(
    network_info.base.inbox,
    baseWallet,
  )

  const basePolyNativeProver: PolyNativeProver = PolyNativeProver__factory.connect(
    network_info.base.prover,
    baseWallet,
  )
  console.log('🏗️  binding contracts on optimism and base...')
  /// FULL TRANSACTION FLOW: intent flow going from Optimism to Base ///

  /// INTENT SOURCE TRANSACTION FLOW ///

  console.log('🏁 Starting full transaction flow...')

  const optimismTimestamp = await optimismProvider
    .getBlock('latest')
    .then((block) => {
      if (!block) throw new Error('Failed to fetch optimism block')
      return block.timestamp
    })

  const transferData = TestERC20__factory.createInterface().encodeFunctionData(
    'transfer',
    [baseWallet.address, network_info.base.usdcAmount],
  )
  const routeTokens: TokenAmount[] = [
    {
      token: network_info.base.usdc,
      amount: network_info.base.usdcAmount,
    },
  ]
  const routeCalls: Call[] = [
    {
      target: network_info.base.usdc,
      data: transferData,
      value: 0,
    },
  ]
  const rewardTokens: TokenAmount[] = [
    {
      token: network_info.optimism.usdc,
      amount: network_info.optimism.usdcRewardAmount,
    },
  ]
  const reward: Reward = {
    creator: optimismWallet.address,
    prover: network_info.optimism.prover,
    deadline: optimismTimestamp + 60 * 30, // 30 minutes from now
    nativeValue: BigInt(0),
    tokens: rewardTokens,
  }
  const rewards: Reward[] = Array(batchSize).fill(reward)
  const intents: Intent[] = []
  const intentHashes: string[] = []
  const routes: Route[] = []
  const calcIntentHashes: string[] = []
  const calcRouteHashes: string[] = []
  const calcRewardHashes: string[] = []

  for (let i = 0; i < batchSize; i++) {
    const route: Route = {
      salt: ethers.hexlify(ethers.randomBytes(32)), //unique identifier for the intent
      source: network_info.optimism.chainId, //source chainId
      destination: network_info.base.chainId, //destination chainId
      inbox: network_info.base.inbox, //destination inbox
      tokens: routeTokens, //tokens required for execution of calls on destination chain
      calls: routeCalls, //calls to execute on the destination chain
    }
    const intent: Intent = {
      route,
      reward,
    }


    const approvalTx = await optimismUSDC.approve(
      optimismIntentSource.getAddress(),
      network_info.optimism.usdcRewardAmount,
    )
    const approvalTxReceipt = await approvalTx.wait()
    if (!approvalTxReceipt) {
      throw new Error('Transaction failed: No receipt received')
    }

    const intentTxOptimism = await optimismIntentSource.publishIntent(
      intent,
      true,
    )

    const intentTxReceipt = await intentTxOptimism.wait()
    if (!intentTxReceipt) {
      throw new Error('Transaction failed: No receipt received')
    }

    const intentCreatedEvent = intentTxReceipt.logs.find(
      (log) =>
        log.topics[0] ===
        optimismIntentSource.interface.getEvent('IntentCreated').topicHash,
    )

    if (!intentCreatedEvent) {
      throw new Error('Transaction failed: IntentCreated event not found')
    }

    const intentHash = intentCreatedEvent.topics[1]
    if (!intentHash) {
      throw new Error('Transaction failed: Intent hash not found in event')
    }

    console.log(`✅ Submitted intent ${i + 1} of ${batchSize} on optimism!`)
    console.log('   Transaction Hash:', intentTxOptimism.hash)

    const [calcIntentHash, calcRouteHash, calcRewardHash] =
    await optimismIntentSource.getIntentHash(intent)
    
    if (calcIntentHash !== intentHash) {
      throw new Error('Transaction failed: Intent hash mismatch')
    }

    intents.push(intent)
    intentHashes.push(intentHash)
    routes.push(route)
    calcIntentHashes.push(calcIntentHash)
    calcRouteHashes.push(calcRouteHash)
    calcRewardHashes.push(calcRewardHash)
  } 


  console.log(' Submitted all intents on optimism!')
  console.log(`    IntentSource at ${network_info.optimism.intentSource}`)
  console.log(`    Destination Inbox at ${network_info.base.inbox}`)
  console.log(
    `    Intent Request:  ${network_info.base.usdcAmount}  USDC to address ${baseWallet.address}`,
  )
  console.log(`    Reward:  ${network_info.optimism.usdcRewardAmount} USDC`)


  /// INBOX TRANSACTION FLOW ///

  for (let i = 0; i < batchSize; i++) {

    const route = routes[i]
    const calcIntentHash = calcIntentHashes[i]
    const calcRewardHash = calcRewardHashes[i]

    const approvalTxBase = await baseUSDC.approve(
      network_info.base.inbox,
      network_info.base.usdcAmount,
    )

    const approvalTxBaseReceipt = await approvalTxBase.wait()
    if (!approvalTxBaseReceipt) {
      throw new Error('Transaction failed: No receipt received')
    }

    const baseInboxSolve = await baseInbox.fulfillSilent(
      route,
      calcRewardHash,
      baseWallet.address,
      calcIntentHash,
    )

    const baseInboxTxReceipt = await baseInboxSolve.wait()
    if (!baseInboxTxReceipt) {
      throw new Error('Transaction failed: No receipt received')
    }

    console.log(`\n✅ Fufilled intent ${i + 1} of ${batchSize} on base!`)
    console.log('   Transaction Hash:', baseInboxSolve.hash)
  }
  console.log('\n✅ Fufilled all intents on base!')

  /// Batch Emit Proofs ///

  console.log('\n🔄 Emitting batch proof...')
  const baseInboxBatch = await baseInbox.batchStorageEmit(
    network_info.base.chainId,
    intentHashes,
  )

  const baseBatchStorageReceipt = await baseInboxBatch.wait()
  if (!baseBatchStorageReceipt) {
    throw new Error('Transaction failed: No receipt received')
  }
  console.log('\n✅ Batch proof emitted!')

  /// PROVER TRANSACTION FLOW ///

  const blockNumber = baseBatchStorageReceipt.blockNumber
  if (!blockNumber) {
    throw new Error('Transaction failed: Block number not found in receipt')
  }

  const txIndex = baseBatchStorageReceipt.index
  if (!txIndex) {
    throw new Error(
      'Transaction failed: Transaction index not found in receipt',
    )
  }
  
  // get batch event
  const localLogIndex = baseBatchStorageReceipt.logs.findIndex(
    (log) =>
      log.topics[0] === baseInbox.interface.getEvent('BatchToBeProven').topicHash,
  )
  if (localLogIndex === -1) {
    throw new Error('Transaction failed: BatchToBeProven event not found in receipt')
  }

  // Print BatchToBeProven event data
  const batchEvent = baseBatchStorageReceipt.logs[localLogIndex]
  console.log('\n📜 BatchToBeProven event:')
  console.log('   Data:', batchEvent.data)
  console.log('   Topics:', batchEvent.topics)

  // Wait 5 seconds for indexer to catch up
  console.log('\n⏳ Waiting 5 seconds for indexer...')
  await new Promise((resolve) => setTimeout(resolve, 5000))

  console.log('\n📝 Proof request inputs:')
  console.log('   Chain ID:', network_info.base.chainId)
  console.log('   Block Number:', blockNumber)
  console.log('   Transaction Index:', txIndex) 
  console.log('   Local Log Index:', localLogIndex)

  const proofRequest = await requestProof({
    chainId: network_info.base.chainId,
    blockNumber,
    txIndex,
    localLogIndex,
  })

  console.log('\n🚀 Proof request sent:', proofRequest)
  console.log('🔄 Polling for proof generation...')

  const proof = await pollForProof(proofRequest.result)

  console.log('🛸 Mission Control: Proof acquired')
  console.log('📜 Raw proof: ', proof.result.proof)

  // Convert base64 proof to hex
  const hexProof = base64ToHex(proof.result.proof)
  console.log('📜 Hex proof:', hexProof)
  console.log('🔄 Converted proof to hex format')

  /// POLYMER PROVER CONTRACT FLOW ///
  console.log('🔄 Validating proof...')

  
  const proveTx = await optimismPolyNativeProver.validatePacked(hexProof)

  const proveTxReceipt = await proveTx.wait()
  if (!proveTxReceipt) {
    throw new Error('Transaction failed: No receipt received')
  }

  // Find and verify all IntentProven events
  const intentProvenEvents = proveTxReceipt.logs.filter(
    (log) =>
      log.topics[0] ===
      optimismPolyNativeProver.interface.getEvent('IntentProven').topicHash,
  )

  if (intentProvenEvents.length !== batchSize) {
    throw new Error(`Expected ${batchSize} IntentProven events, but found ${intentProvenEvents.length}`)
  }

  // Verify each event matches our intent hashes
  for (let i = 0; i < batchSize; i++) {
    const [provenIntentHash, provenClaimant] =
      optimismPolyNativeProver.interface.decodeEventLog(
        'IntentProven',
        intentProvenEvents[i].data,
        intentProvenEvents[i].topics,
      )

    if (provenIntentHash !== intentHashes[i]) {
      throw new Error(
        `Intent hash mismatch. Expected: ${intentHashes[i]}, Got: ${provenIntentHash}`,
      )
    }

    if (provenClaimant.toLowerCase() !== optimismWallet.address.toLowerCase()) {
      throw new Error(
        `Claimant mismatch. Expected: ${optimismWallet.address.toLowerCase()}, Got: ${provenClaimant.toLowerCase()}`,
      )
    }

    console.log(`✅ Proof ${i + 1} of ${batchSize} validated successfully!`)
    console.log('   Intent Hash:', provenIntentHash)
    console.log('   Claimant:', provenClaimant)
  }

  console.log('✅ All proofs validated successfully!')
  console.log('   Transaction Hash: ', proveTx.hash)

  /// CLAIM REWARDS INTENT FLOW ///

  const claimTx = await optimismIntentSource.batchWithdraw(
    calcRouteHashes,
    rewards,
  )

  const claimTxReceipt = await claimTx.wait()
  if (!claimTxReceipt) {
    throw new Error('Transaction failed: No receipt received')
  }

  // Find and verify all Withdrawal events
  const withdrawalEvents = claimTxReceipt.logs.filter(
    (log) =>
      log.topics[0] ===
      optimismIntentSource.interface.getEvent('Withdrawal').topicHash,
  )

  if (withdrawalEvents.length !== batchSize) {
    throw new Error(`Expected ${batchSize} Withdrawal events, but found ${withdrawalEvents.length}`)
  }

  // Verify each withdrawal event matches our intent hashes
  for (let i = 0; i < batchSize; i++) {
    const [withdrawalIntentHash, withdrawalClaimant] =
      optimismIntentSource.interface.decodeEventLog(
        'Withdrawal',
        withdrawalEvents[i].data,
        withdrawalEvents[i].topics,
      )


    if (withdrawalIntentHash.toLowerCase() !== calcIntentHashes[i].toLowerCase()) {
      throw new Error(
        `Intent hash mismatch. Expected: ${calcIntentHashes[i]}, Got: ${withdrawalIntentHash}`,
      )
    }

    if (withdrawalClaimant.toLowerCase() !== optimismWallet.address.toLowerCase()) {
      throw new Error(
        `Claimant mismatch. Expected: ${optimismWallet.address.toLowerCase()}, Got: ${withdrawalClaimant.toLowerCase()}`,
      )
    }

    console.log(`✅ Withdrawal ${i + 1} of ${batchSize} validated successfully!`)
    console.log('   Intent Hash:', withdrawalIntentHash)
    console.log('   Claimant:', withdrawalClaimant)
  }

  console.log('\n✅ All withdrawals validated successfully!')
  console.log('   Transaction Hash: ', claimTx.hash)

  console.log('\n🎉 ✨ 🚀 POLYMER PACKED INTENT FLOW COMPLETED! 🚀 ✨ 🎉')
  console.log(`🔄 ${batchSize} Intents Created & Funded`)
  console.log(`✅ ${batchSize} Intents Fulfilled`) 
  console.log(`📜 1 Proofs Generated & Validated`)
  console.log(`💎 ${batchSize} Rewards Successfully Claimed`)
  console.log('🏁 All Steps Completed Successfully! 🏁\n')

  console.log(
    'Batch Proof Submission: ',
    network_info.optimism.explorer + proveTx.hash,
  )
  console.log(
    'Batch Rewards Withdrawal: ',
    network_info.optimism.explorer + claimTx.hash,
  )
}

async function requestProof({
  chainId,
  blockNumber,
  txIndex,
  localLogIndex,
}: ProofRequestParams) {
  const POLYMER_API_URL = process.env.POLYMER_API_URL
  const POLYMER_API_KEY = process.env.POLYMER_API_KEY

  if (!POLYMER_API_URL || !POLYMER_API_KEY) {
    throw new Error(
      'POLYMER_API_URL or POLYMER_API_KEY environment variable not found',
    )
  }

  const response = await axios.post(
    POLYMER_API_URL,
    {
      jsonrpc: '2.0',
      id: 1,
      method: 'log_requestProof',
      params: [chainId, blockNumber, txIndex, localLogIndex],
    },
    {
      headers: {
        Authorization: `Bearer ${POLYMER_API_KEY}`,
      },
    },
  )

  return response.data
}

async function pollForProof(jobId: string, maxAttempts = 60) {
  const POLYMER_API_URL = process.env.POLYMER_API_URL
  const POLYMER_API_KEY = process.env.POLYMER_API_KEY

  if (!POLYMER_API_URL || !POLYMER_API_KEY) {
    throw new Error(
      'POLYMER_API_URL or POLYMER_API_KEY environment variable not found',
    )
  }

  let attempts = 0
  let proofResponse

  while (attempts < maxAttempts) {
    proofResponse = await axios.post(
      POLYMER_API_URL,
      {
        jsonrpc: '2.0',
        id: 1,
        method: 'log_queryProof',
        params: [jobId],
      },
      {
        headers: {
          Authorization: `Bearer ${POLYMER_API_KEY}`,
        },
      },
    )

    if (proofResponse?.data?.result?.proof) {
      console.log('✅ Proof generated successfully!')
      return proofResponse.data
    }

    attempts++
    console.log(`⏳ Waiting for proof... Attempt ${attempts}/${maxAttempts}`)
    await new Promise((resolve) => setTimeout(resolve, 2000)) // Wait 2 seconds between attempts
  }

  throw new Error('Proof generation timed out')
}

// Convert base64 to hex
function base64ToHex(base64: string): string {
  // Convert base64 to buffer
  const buffer = Buffer.from(base64, 'base64')
  // Convert buffer to hex string with 0x prefix
  return '0x' + buffer.toString('hex')
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
