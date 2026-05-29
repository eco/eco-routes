/**
 * run-evm-tron-polymer-intent.ts
 *
 * Full lifecycle for an EVM → Tron intent using the Polymer prover:
 *   1. Approve USDC + PublishAndFund on EVM (Base): locks reward in vault
 *   2. Approve USDT + FulfillAndProve on Tron: solver fulfills + Tron PolymerProver
 *      emits IntentFulfilledFromSource(evmChainId, encodedProofs)
 *   3. Fetch cross-chain proof from Polymer JSON-RPC API:
 *        proof_request(srcChainId, srcBlockNumber, globalLogIndex) → jobId
 *        proof_query(jobId) → base64 proof
 *   4. Submit proof to EVM PolymerProver.validate(bytes proof)
 *   5. Withdraw USDC reward on EVM
 *
 * Required env vars:
 *   PRIVATE_KEY           hex private key (with or without 0x)
 *   ALCHEMY_API_KEY       for Base RPC (or set EVM_RPC_URL directly)
 *   POLYMER_PROVER_API    Polymer JSON-RPC API base URL
 *                          mainnet:  https://api.polymer.zone/v1/
 *                          testnet:  https://api.testnet.polymer.zone/v1/
 *   POLYMER_API_KEY       API key for Polymer (passed as Bearer token)
 *
 * Optional env vars (defaults to deployed mainnet addresses):
 *   EVM_RPC_URL                   override Base RPC URL
 *   EVM_PORTAL                    EVM portal address
 *   EVM_POLYMER_PROVER            EVM PolymerProver address (default: deployed)
 *   TRON_RPC_URL                  (default: https://api.trongrid.io)
 *   TRON_PORTAL_HEX20             Tron portal hex20 address
 *   TRON_POLYMER_PROVER_HEX20     Tron PolymerProver hex20 address (default: deployed)
 *   POLYMER_SRC_CHAIN_ID          Polymer's chain ID for Tron (default: 728126428)
 *   POLL_INTERVAL_SEC             (default: 30)
 *   POLL_TIMEOUT_MIN              (default: 60)
 *
 * Usage:
 *   set -a && source .env && set +a
 *   npx ts-node scripts/tron/run-evm-tron-polymer-intent.ts
 */

import { ethers } from 'ethers'
import { TronWeb } from 'tronweb'
import 'dotenv/config'

// ─── Token addresses ──────────────────────────────────────────────────────────

const EVM_USDC_BY_CHAIN: Record<number, string> = {
  1:     '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
  10:    '0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85',
  8453:  '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
  42161: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831',
}

const TRON_USDT_HEX_BY_CHAIN: Record<number, string> = {
  728126428:  '0xa614f803b6fd780986a42c78ec9c7f77e6ded13c', // mainnet TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t
  2494104990: '0xc060ca2c712ba701f9663750ff447fb7b48e42f1', // Shasta
}

const EVM_CHAIN_NAMES: Record<number, string> = {
  1: 'Ethereum', 10: 'Optimism', 8453: 'Base', 42161: 'Arbitrum',
}

// ─── Constants ────────────────────────────────────────────────────────────────

const REWARD_AMOUNT = 100_000n  // 0.1 USDC  (6 decimals)
const ROUTE_AMOUNT  = 100_000n  // 0.1 USDT  (6 decimals)

/** Recipient of the USDT transfer on Tron (hex20) */
const TRON_RECIPIENT_HEX20 = '0xffe05fc55f42a9ae9eb97731c1ca1e0aa9030fde' // TZJA6m9Jy9FGhhs7wFffag8dAYsEZdQ7Xh

const TRON_EXPLORER = 'https://tronscan.org/#/transaction'

/** Keccak256 topic[0] of IntentFulfilledFromSource(uint64,bytes) — without 0x */
const INTENT_FULFILLED_TOPIC_NO0X = ethers.keccak256(
  ethers.toUtf8Bytes('IntentFulfilledFromSource(uint64,bytes)'),
).slice(2).toLowerCase()

// ─── ABIs / interfaces ────────────────────────────────────────────────────────

const PUBLISH_AND_FUND_ABI = [
  `function publishAndFund(
    tuple(
      uint64 destination,
      tuple(bytes32 salt,uint64 deadline,address portal,uint256 nativeAmount,
            tuple(address token,uint256 amount)[] tokens,
            tuple(address target,bytes data,uint256 value)[] calls) route,
      tuple(uint64 deadline,address creator,address prover,uint256 nativeAmount,
            tuple(address token,uint256 amount)[] tokens) reward
    ) intent,
    bool allowPartial
  ) external payable returns (bytes32 intentHash, address vault)`,
]

const BATCH_WITHDRAW_ABI = [
  {
    type: 'function', name: 'batchWithdraw',
    inputs: [
      { name: 'destinations', type: 'uint64[]' },
      { name: 'routeHashes',  type: 'bytes32[]' },
      { name: 'rewards', type: 'tuple[]', components: [
        { name: 'deadline',     type: 'uint64' },
        { name: 'creator',      type: 'address' },
        { name: 'prover',       type: 'address' },
        { name: 'nativeAmount', type: 'uint256' },
        { name: 'tokens', type: 'tuple[]', components: [
          { name: 'token', type: 'address' }, { name: 'amount', type: 'uint256' },
        ]},
      ]},
    ],
    outputs: [], stateMutability: 'nonpayable',
  },
]

const POLYMER_PROVER_ABI = [
  'function validate(bytes calldata proof) external',
  'function provenIntents(bytes32) external view returns (tuple(address claimant, uint64 destination))',
]

const ERC20_ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
  'function balanceOf(address) view returns (uint256)',
]

const TRANSFER_IFACE = new ethers.Interface(['function transfer(address to, uint256 amount) returns (bool)'])

const FULFILL_AND_PROVE_IFACE = new ethers.Interface([
  `function fulfillAndProve(
    bytes32 intentHash,
    tuple(bytes32 salt,uint64 deadline,address portal,uint256 nativeAmount,
          tuple(address token,uint256 amount)[] tokens,
          tuple(address target,bytes data,uint256 value)[] calls) route,
    bytes32 rewardHash,
    bytes32 claimant,
    address prover,
    uint64 sourceChainDomainID,
    bytes data
  ) external payable returns (bytes[] memory)`,
])

const FULFILL_AND_PROVE_SIG =
  'fulfillAndProve(bytes32,(bytes32,uint64,address,uint256,(address,uint256)[],(address,bytes,uint256)[]),bytes32,bytes32,address,uint64,bytes)'

// ─── Metrics ─────────────────────────────────────────────────────────────────

interface StepMetrics {
  name: string
  durationMs: number
  evmTxs: { label: string; gasUsed: bigint; gasPrice: bigint; costEth: string }[]
  tronTxs: { label: string; energyUsed: number; energyFee: number; netFee: number; bandwidthUsed: number }[]
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))

function tronChainIdFromRpcUrl(url: string): number {
  if (url.includes('shasta')) return 2494104990
  if (url.includes('nile'))   return 3448148188
  return 728126428
}

function evmExplorer(chainId: bigint): string {
  const m: Record<string, string> = {
    '1': 'https://etherscan.io', '10': 'https://optimistic.etherscan.io',
    '8453': 'https://basescan.org', '42161': 'https://arbiscan.io',
  }
  return m[chainId.toString()] ?? 'https://etherscan.io'
}

async function tronSendAndWait(
  tw: TronWeb,
  contractB58: string,
  funcSig: string,
  rawParameter: string,
  callValue = 0,
): Promise<{ txid: string; info: any }> {
  const result = await tw.transactionBuilder.triggerSmartContract(
    contractB58, funcSig,
    { feeLimit: 1_000_000_000, callValue, rawParameter },
    [],
  )
  if (!result.result?.result) throw new Error(`triggerSmartContract failed: ${JSON.stringify(result)}`)
  const signed    = await tw.trx.sign(result.transaction)
  const broadcast = await tw.trx.sendRawTransaction(signed)
  if (!broadcast.result) throw new Error(`Broadcast failed: ${JSON.stringify(broadcast)}`)
  for (let i = 0; i < 60; i++) {
    await sleep(3000)
    const info: any = await tw.trx.getTransactionInfo(broadcast.txid)
    if (info?.id) {
      if (info.receipt?.result !== 'SUCCESS') throw new Error(`Tx reverted: ${JSON.stringify(info)}`)
      return { txid: broadcast.txid, info }
    }
  }
  throw new Error(`Timed out waiting for ${broadcast.txid}`)
}

// ─── Tron globalLogIndex computation ─────────────────────────────────────────

/**
 * Polymer's proof_request requires the globalLogIndex: the sequential index of
 * the target log across ALL transactions in the block (0-indexed, block-scoped).
 *
 * To compute it:
 *   1. Get the full block to determine the tx order.
 *   2. For each tx that appears before our tx in the block, count its emitted logs.
 *   3. Add the index of our target event within our own tx's logs.
 */
async function getGlobalLogIndex(
  tw: TronWeb,
  txid: string,
  txInfo: any,
  targetTopicNo0x: string,
): Promise<{ blockNumber: number; globalLogIndex: number }> {
  const blockNumber: number = txInfo.blockNumber

  // Get block to find tx ordering
  const block: any = await (tw.trx as any).getBlock(blockNumber)
  const txIds: string[] = (block.transactions ?? []).map((t: any) =>
    typeof t === 'string' ? t : (t.txID ?? t.hash ?? ''),
  )

  const myIndex = txIds.findIndex(id => id.toLowerCase() === txid.toLowerCase())
  if (myIndex === -1) throw new Error(`Tx ${txid} not found in block ${blockNumber}`)

  // Sum up log counts from all txs before ours
  let globalIndex = 0
  for (let i = 0; i < myIndex; i++) {
    const prevInfo: any = await tw.trx.getTransactionInfo(txIds[i])
    globalIndex += (prevInfo.log ?? []).length
  }

  // Find the target event's index within our tx's logs
  const myLogs: any[] = txInfo.log ?? []
  const localIndex = myLogs.findIndex(
    (log: any) => log.topics?.[0]?.toLowerCase() === targetTopicNo0x,
  )
  if (localIndex === -1) throw new Error(`Target event not found in tx ${txid} logs`)

  return { blockNumber, globalLogIndex: globalIndex + localIndex }
}

// ─── Step 1: Create and fund intent on EVM ────────────────────────────────────

async function createIntentOnEvm(
  wallet: ethers.Wallet,
  evmPortal: string,
  evmPolymerProver: string,
  evmUsdcAddr: string,
  tronPortalHex: string,
  tronUsdtHex: string,
  tronChainId: number,
  chainName: string,
): Promise<{ intentHash: string; routeHash: string; salt: string; deadline: number; txHash: string; metrics: StepMetrics }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 1 — Approve USDC + PublishAndFund on ${chainName}`)
  console.log(`${'─'.repeat(60)}`)

  const t0 = Date.now()
  const metrics: StepMetrics = { name: 'Step 1: Create intent (Base)', durationMs: 0, evmTxs: [], tronTxs: [] }

  const abiCoder = ethers.AbiCoder.defaultAbiCoder()
  const deadline = Math.floor(Date.now() / 1000) + 24 * 60 * 60
  const salt     = ethers.keccak256(ethers.toUtf8Bytes(`eco-polymer-${Date.now()}`))
  const creator  = wallet.address.toLowerCase()

  const transferData = TRANSFER_IFACE.encodeFunctionData('transfer', [TRON_RECIPIENT_HEX20, ROUTE_AMOUNT])

  const route = {
    salt,
    deadline:     BigInt(deadline),
    portal:       tronPortalHex,
    nativeAmount: 0n,
    tokens: [{ token: tronUsdtHex, amount: ROUTE_AMOUNT }],
    calls:  [{ target: tronUsdtHex, data: transferData, value: 0n }],
  }
  const reward = {
    deadline:     BigInt(deadline),
    creator,
    prover:       evmPolymerProver,
    nativeAmount: 0n,
    tokens: [{ token: evmUsdcAddr, amount: REWARD_AMOUNT }],
  }
  const intent = { destination: tronChainId, route, reward }

  console.log(`  Wallet:   ${wallet.address}`)
  console.log(`  Deadline: ${new Date(deadline * 1000).toISOString()}`)
  console.log(`  Reward:   0.1 USDC locked on ${chainName}`)
  console.log(`  Want:     0.1 USDT → TZJA6m9Jy9FGhhs7wFffag8dAYsEZdQ7Xh on Tron`)

  console.log(`  Approving 0.1 USDC to portal...`)
  const usdc = new ethers.Contract(evmUsdcAddr, ERC20_ABI, wallet)
  const approveTx = await usdc.approve(evmPortal, REWARD_AMOUNT)
  const approveReceipt = await approveTx.wait()
  metrics.evmTxs.push({
    label: 'approve USDC',
    gasUsed: approveReceipt.gasUsed,
    gasPrice: approveReceipt.gasPrice ?? approveReceipt.effectiveGasPrice ?? 0n,
    costEth: ethers.formatEther(approveReceipt.gasUsed * (approveReceipt.gasPrice ?? approveReceipt.effectiveGasPrice ?? 0n)),
  })

  console.log(`  Sending publishAndFund...`)
  const portal  = new ethers.Contract(evmPortal, PUBLISH_AND_FUND_ABI, wallet)
  const tx      = await portal.publishAndFund(intent, false)
  const receipt = await tx.wait()
  metrics.evmTxs.push({
    label: 'publishAndFund',
    gasUsed: receipt.gasUsed,
    gasPrice: receipt.gasPrice ?? receipt.effectiveGasPrice ?? 0n,
    costEth: ethers.formatEther(receipt.gasUsed * (receipt.gasPrice ?? receipt.effectiveGasPrice ?? 0n)),
  })

  const topic = ethers.id(
    'IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])',
  )
  let intentHash = ''
  for (const log of receipt.logs) {
    if (log.topics[0] === topic) { intentHash = log.topics[1]; break }
  }
  if (!intentHash) throw new Error('IntentPublished event not found in receipt')

  const routeHash = ethers.keccak256(
    abiCoder.encode(
      ['tuple(bytes32 salt,uint64 deadline,address portal,uint256 nativeAmount,tuple(address token,uint256 amount)[] tokens,tuple(address target,bytes data,uint256 value)[] calls)'],
      [route],
    ),
  )

  metrics.durationMs = Date.now() - t0
  console.log(`  done.  intentHash: ${intentHash}`)
  return { intentHash, routeHash, salt, deadline, txHash: tx.hash, metrics }
}

// ─── Step 2: Fulfill + prove on Tron ─────────────────────────────────────────

async function fulfillAndProveOnTron(
  tw: TronWeb,
  tronPortalB58: string,
  tronPortalHex: string,
  tronPolymerProverHex: string,
  tronUsdtHex: string,
  evmPolymerProver: string,
  evmUsdcAddr: string,
  evmChainId: number,
  intentHash: string,
  salt: string,
  deadline: number,
  creatorHex: string,
): Promise<{ txid: string; blockNumber: number; globalLogIndex: number; metrics: StepMetrics }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 2 — Approve USDT + FulfillAndProve on Tron`)
  console.log(`${'─'.repeat(60)}`)

  const t0 = Date.now()
  const metrics: StepMetrics = { name: 'Step 2: Fulfill + prove (Tron)', durationMs: 0, evmTxs: [], tronTxs: [] }

  const abiCoder  = ethers.AbiCoder.defaultAbiCoder()
  const tronUsdtB58 = tw.address.fromHex('41' + tronUsdtHex.slice(2)) as string

  const deployerAddr  = tw.address.fromPrivateKey(tw.defaultPrivateKey as string) as string
  const deployerHex20 = '0x' + (tw.address.toHex(deployerAddr) as string).slice(2)

  const transferData = TRANSFER_IFACE.encodeFunctionData('transfer', [TRON_RECIPIENT_HEX20, ROUTE_AMOUNT])

  const route = {
    salt,
    deadline:     BigInt(deadline),
    portal:       tronPortalHex,
    nativeAmount: 0n,
    tokens: [{ token: tronUsdtHex, amount: ROUTE_AMOUNT }] as any[],
    calls:  [{ target: tronUsdtHex, data: transferData, value: 0n }] as any[],
  }
  const reward = {
    deadline:     BigInt(deadline),
    creator:      creatorHex,
    prover:       evmPolymerProver,
    nativeAmount: 0n,
    tokens: [{ token: evmUsdcAddr, amount: REWARD_AMOUNT }] as any[],
  }

  const rewardHash = ethers.keccak256(
    abiCoder.encode(
      ['tuple(uint64 deadline,address creator,address prover,uint256 nativeAmount,tuple(address token,uint256 amount)[] tokens)'],
      [reward],
    ),
  )

  const claimant = ethers.zeroPadValue(deployerHex20, 32)

  // Polymer prove() is free (no bridge fee)
  const calldata = FULFILL_AND_PROVE_IFACE.encodeFunctionData('fulfillAndProve', [
    intentHash, route, rewardHash, claimant,
    tronPolymerProverHex,
    evmChainId,  // sourceChainDomainID = EVM chain where rewards are held
    '0x',
  ])

  console.log(`  Approving 0.05 USDT to Tron portal...`)
  const { info: approveInfo } = await tronSendAndWait(
    tw, tronUsdtB58, 'approve(address,uint256)',
    new ethers.Interface(['function approve(address,uint256)']).encodeFunctionData('approve', [tronPortalHex, ROUTE_AMOUNT]).slice(10),
  )
  metrics.tronTxs.push({
    label: 'approve USDT',
    energyUsed: approveInfo.receipt?.energy_usage_total ?? 0,
    energyFee:  approveInfo.receipt?.energy_fee ?? 0,
    netFee:     approveInfo.fee ?? 0,
    bandwidthUsed: approveInfo.receipt?.net_usage ?? 0,
  })

  console.log(`  Sending fulfillAndProve (Polymer)...`)
  const { txid, info } = await tronSendAndWait(
    tw, tronPortalB58, FULFILL_AND_PROVE_SIG, calldata.slice(10),
  )
  metrics.tronTxs.push({
    label: 'fulfillAndProve',
    energyUsed: info.receipt?.energy_usage_total ?? 0,
    energyFee:  info.receipt?.energy_fee ?? 0,
    netFee:     info.fee ?? 0,
    bandwidthUsed: info.receipt?.net_usage ?? 0,
  })
  console.log(`  done.  txid: ${txid}`)
  console.log(`  ${TRON_EXPLORER}/${txid}`)

  // Compute globalLogIndex — Polymer needs this to identify the exact log in the block
  console.log(`  Computing globalLogIndex...`)
  const { blockNumber, globalLogIndex } = await getGlobalLogIndex(
    tw, txid, info, INTENT_FULFILLED_TOPIC_NO0X,
  )
  console.log(`  blockNumber: ${blockNumber}  globalLogIndex: ${globalLogIndex}`)

  metrics.durationMs = Date.now() - t0
  return { txid, blockNumber, globalLogIndex, metrics }
}

// ─── Step 3: Fetch proof from Polymer API ─────────────────────────────────────

/**
 * Polymer JSON-RPC API — pull model, two calls:
 *
 *   proof_request(srcChainId, srcBlockNumber, globalLogIndex) → jobId
 *   proof_query(jobId) → { status, proof (base64) }
 *
 * Proof is returned as base64; convert to hex bytes before calling validate().
 */
async function fetchPolymerProof(
  apiBase: string,
  apiKey: string,
  polymerSrcChainId: number,
  srcBlockNumber: number,
  globalLogIndex: number,
  intervalSec: number,
  timeoutMin: number,
): Promise<{ proofHex: string; metrics: StepMetrics }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 3 — Fetch Polymer cross-chain proof`)
  console.log(`${'─'.repeat(60)}`)
  console.log(`  srcChainId:     ${polymerSrcChainId}`)
  console.log(`  srcBlockNumber: ${srcBlockNumber}`)
  console.log(`  globalLogIndex: ${globalLogIndex}`)
  console.log(`  API:            ${apiBase}`)

  const t0 = Date.now()
  const metrics: StepMetrics = { name: 'Step 3: Fetch Polymer proof', durationMs: 0, evmTxs: [], tronTxs: [] }

  async function rpc(method: string, params: any[]): Promise<any> {
    const resp = await fetch(apiBase, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}),
      },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    })
    const text = await resp.text()
    if (!resp.ok) throw new Error(`Polymer API HTTP ${resp.status}: ${text.trim()}`)
    const json = JSON.parse(text) as any
    if (json.error) throw new Error(`Polymer API error: ${JSON.stringify(json.error)}`)
    return json.result
  }

  // 1. Submit proof request → get jobId
  const jobId = await rpc('proof_request', [{
    srcChainId:     polymerSrcChainId,
    srcBlockNumber,
    globalLogIndex,
  }])
  console.log(`  jobId: ${jobId}`)

  // 2. Poll until proof is ready
  const polls  = Math.ceil((timeoutMin * 60) / intervalSec)
  for (let i = 1; i <= polls; i++) {
    await sleep(intervalSec * 1000)
    const result = await rpc('proof_query', [jobId])
    console.log(`  [${i}/${polls}] status: ${result?.status ?? 'pending'}`)
    if (result?.status === 'complete') {
      // Proof is base64-encoded; decode to hex for on-chain submission
      const proofBase64: string = result.proof
      const proofBytes  = Buffer.from(proofBase64, 'base64')
      const proofHex    = '0x' + proofBytes.toString('hex')
      console.log(`  Proof ready (${proofBytes.length} bytes)`)
      metrics.durationMs = Date.now() - t0
      return { proofHex, metrics }
    }
    if (result?.status === 'error') {
      throw new Error(`Polymer proof job failed: ${JSON.stringify(result)}`)
    }
  }
  throw new Error(`Polymer proof not ready within ${timeoutMin} minutes`)
}

// ─── Step 4: Validate proof on EVM ────────────────────────────────────────────

async function validateOnEvm(
  wallet: ethers.Wallet,
  evmPolymerProver: string,
  intentHash: string,
  proof: string,
): Promise<{ txHash: string; metrics: StepMetrics }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 4 — Submit proof to EVM PolymerProver.validate()`)
  console.log(`${'─'.repeat(60)}`)

  const t0 = Date.now()
  const metrics: StepMetrics = { name: 'Step 4: Validate proof (Base)', durationMs: 0, evmTxs: [], tronTxs: [] }

  const prover = new ethers.Contract(evmPolymerProver, POLYMER_PROVER_ABI, wallet)

  console.log(`  Sending validate()...`)
  const tx = await prover.validate(proof)
  const receipt = await tx.wait()
  metrics.evmTxs.push({
    label: 'validate',
    gasUsed: receipt.gasUsed,
    gasPrice: receipt.gasPrice ?? receipt.effectiveGasPrice ?? 0n,
    costEth: ethers.formatEther(receipt.gasUsed * (receipt.gasPrice ?? receipt.effectiveGasPrice ?? 0n)),
  })
  console.log(`  done.  tx: ${tx.hash}`)

  const proofData = await prover.provenIntents(intentHash)
  console.log(`  provenIntents[${intentHash}]:`)
  console.log(`    claimant:    ${proofData.claimant}`)
  console.log(`    destination: ${proofData.destination}`)

  if (proofData.claimant === ethers.ZeroAddress) {
    throw new Error('validate() succeeded but intent not marked as proven — check proof data')
  }

  metrics.durationMs = Date.now() - t0
  return { txHash: tx.hash, metrics }
}

// ─── Step 5: Withdraw reward on EVM ───────────────────────────────────────────

async function withdrawOnEvm(
  wallet: ethers.Wallet,
  evmPortal: string,
  evmPolymerProver: string,
  evmUsdcAddr: string,
  tronPortalHex: string,
  tronUsdtHex: string,
  tronChainId: number,
  routeHash: string,
  deadline: number,
  creatorHex: string,
): Promise<{ txHash: string; metrics: StepMetrics }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 5 — Withdraw USDC reward on EVM`)
  console.log(`${'─'.repeat(60)}`)

  const t0 = Date.now()
  const metrics: StepMetrics = { name: 'Step 5: Withdraw USDC (Base)', durationMs: 0, evmTxs: [], tronTxs: [] }

  const reward = [
    BigInt(deadline),
    creatorHex,
    evmPolymerProver,
    0n,
    [{ token: evmUsdcAddr, amount: REWARD_AMOUNT }],
  ]

  console.log(`  Sending batchWithdraw...`)
  const portal  = new ethers.Contract(evmPortal, BATCH_WITHDRAW_ABI, wallet)
  const tx      = await portal.batchWithdraw([tronChainId], [routeHash], [reward])
  const receipt = await tx.wait()
  metrics.evmTxs.push({
    label: 'batchWithdraw',
    gasUsed: receipt.gasUsed,
    gasPrice: receipt.gasPrice ?? receipt.effectiveGasPrice ?? 0n,
    costEth: ethers.formatEther(receipt.gasUsed * (receipt.gasPrice ?? receipt.effectiveGasPrice ?? 0n)),
  })

  const usdc    = new ethers.Contract(evmUsdcAddr, ERC20_ABI, wallet)
  const balance = await usdc.balanceOf(wallet.address)
  console.log(`  done.  Wallet USDC balance: ${balance} (6 decimals)`)

  metrics.durationMs = Date.now() - t0
  return { txHash: tx.hash, metrics }
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  let pk = process.env.PRIVATE_KEY ?? ''
  if (pk.startsWith('0x')) pk = pk.slice(2)
  if (!pk) throw new Error('PRIVATE_KEY not set')

  const polymerApiBase = process.env.POLYMER_PROVER_API ?? ''
  if (!polymerApiBase) throw new Error(
    'POLYMER_PROVER_API not set\n' +
    '  mainnet: https://api.polymer.zone/v1/\n' +
    '  testnet: https://api.testnet.polymer.zone/v1/',
  )
  const polymerApiKey = process.env.POLYMER_API_KEY ?? ''

  let evmRpcUrl = process.env.EVM_RPC_URL ?? ''
  if (!evmRpcUrl) {
    const key = process.env.ALCHEMY_API_KEY
    if (key) evmRpcUrl = `https://base-mainnet.g.alchemy.com/v2/${key}`
    else throw new Error('EVM_RPC_URL or ALCHEMY_API_KEY not set')
  }

  const evmPortal        = process.env.EVM_PORTAL ?? (process.env.PORTAL_CONTRACT ?? '0x399Dbd5DF04f83103F77A58cBa2B7c4d3cdede97')
  const evmPolymerProver = process.env.EVM_POLYMER_PROVER ?? '0x76aA9cFB1C93F2c45BBeFE37a6a6287ee4aEad6f'
  const tronRpcUrl       = process.env.TRON_RPC_URL ?? 'https://api.trongrid.io'
  const tronProverHex    = process.env.TRON_POLYMER_PROVER_HEX20 ?? '0xe7f69276a1dd97838646a8b49060dcec7416bfaf'
  const pollInterval     = parseInt(process.env.POLL_INTERVAL_SEC ?? '30', 10)
  const pollTimeout      = parseInt(process.env.POLL_TIMEOUT_MIN  ?? '60', 10)

  const provider  = new ethers.JsonRpcProvider(evmRpcUrl)
  const wallet    = new ethers.Wallet('0x' + pk, provider)
  const tronGridKey = process.env.TRONGRID_API_KEY || ''
  const tw        = new TronWeb({
    fullHost: tronRpcUrl,
    privateKey: pk,
    ...(tronGridKey ? { headers: { 'TRON-PRO-API-KEY': tronGridKey } } : {}),
  })

  const { chainId: evmChainIdBig } = await provider.getNetwork()
  const evmChainId  = Number(evmChainIdBig)
  const tronChainId = tronChainIdFromRpcUrl(tronRpcUrl)

  // Chain ID Polymer uses to identify the source chain in proof_request.
  // For Tron mainnet this is 728126428 (block.chainid in TVM) unless Polymer
  // uses a different registry ID — override with POLYMER_SRC_CHAIN_ID if needed.
  const polymerSrcChainId = parseInt(process.env.POLYMER_SRC_CHAIN_ID ?? String(tronChainId), 10)

  const chainName = EVM_CHAIN_NAMES[evmChainId] ?? `chain-${evmChainId}`
  const explorer  = evmExplorer(evmChainIdBig)
  const creator   = wallet.address.toLowerCase()

  // Resolve Tron portal hex20 (accept either hex20 or base58 via env)
  let tronPortalHex = process.env.TRON_PORTAL_HEX20 ?? ''
  if (!tronPortalHex) {
    const b58 = process.env.TRON_PORTAL_CONTRACT ?? ''
    if (!b58) throw new Error('TRON_PORTAL_HEX20 or TRON_PORTAL_CONTRACT not set')
    tronPortalHex = '0x' + (tw.address.toHex(b58) as string).slice(2)
  }
  const tronPortalB58 = tw.address.fromHex('41' + tronPortalHex.slice(2)) as string

  const evmUsdcAddr = EVM_USDC_BY_CHAIN[evmChainId]
  if (!evmUsdcAddr) throw new Error(`No USDC address configured for EVM chain ${evmChainId}`)
  const tronUsdtHex = TRON_USDT_HEX_BY_CHAIN[tronChainId]
  if (!tronUsdtHex) throw new Error(`No USDT address configured for Tron chain ${tronChainId}`)

  console.log(`\n${'═'.repeat(60)}`)
  console.log(`  EVM → Tron  |  Polymer Prover  |  ${chainName} → Tron`)
  console.log(`  Reward:  0.1 USDC locked on ${chainName}`)
  console.log(`  Want:    0.1 USDT → TZJA6m9Jy9FGhhs7wFffag8dAYsEZdQ7Xh on Tron`)
  console.log(`  Wallet:  ${wallet.address}`)
  console.log(`${'═'.repeat(60)}`)

  const totalStart = Date.now()

  // ── Step 1 ──
  const { intentHash, routeHash, salt, deadline, txHash: createTx, metrics: m1 } =
    await createIntentOnEvm(
      wallet, evmPortal, evmPolymerProver, evmUsdcAddr,
      tronPortalHex, tronUsdtHex, tronChainId, chainName,
    )

  // ── Step 2 ──
  const { txid: fulfillTxid, blockNumber, globalLogIndex, metrics: m2 } =
    await fulfillAndProveOnTron(
      tw, tronPortalB58, tronPortalHex, tronProverHex,
      tronUsdtHex, evmPolymerProver, evmUsdcAddr, evmChainId,
      intentHash, salt, deadline, creator,
    )

  // ── Step 3 ──
  const { proofHex: proof, metrics: m3 } = await fetchPolymerProof(
    polymerApiBase, polymerApiKey, polymerSrcChainId,
    blockNumber, globalLogIndex,
    pollInterval, pollTimeout,
  )

  // ── Step 4 ──
  const { txHash: validateTx, metrics: m4 } =
    await validateOnEvm(wallet, evmPolymerProver, intentHash, proof)

  // ── Step 5 ──
  const { txHash: withdrawTx, metrics: m5 } =
    await withdrawOnEvm(
      wallet, evmPortal, evmPolymerProver, evmUsdcAddr,
      tronPortalHex, tronUsdtHex, tronChainId,
      routeHash, deadline, creator,
    )

  const totalMs = Date.now() - totalStart

  // ── Summary ──
  console.log(`\n${'═'.repeat(60)}`)
  console.log(`  SUMMARY`)
  console.log(`${'═'.repeat(60)}`)
  console.log(`  Route:        ${chainName} → Tron (Polymer)`)
  console.log(`  Intent:       ${intentHash}`)
  console.log(`  Block:        ${blockNumber}  logIndex: ${globalLogIndex}`)
  console.log(``)
  console.log(`  1. Create:    ${explorer}/tx/${createTx}`)
  console.log(`  2. Fulfill:   ${TRON_EXPLORER}/${fulfillTxid}`)
  console.log(`  4. Validate:  ${explorer}/tx/${validateTx}`)
  console.log(`  5. Withdraw:  ${explorer}/tx/${withdrawTx}`)

  // ── Metrics ──
  const fmtMs = (ms: number) => {
    if (ms < 60_000) return `${(ms/1000).toFixed(1)}s`
    const m = Math.floor(ms / 60_000)
    const s = ((ms % 60_000) / 1000).toFixed(0).padStart(2, '0')
    return `${m}m ${s}s`
  }

  console.log(`\n${'═'.repeat(60)}`)
  console.log(`  METRICS`)
  console.log(`${'═'.repeat(60)}`)
  console.log(`  Total time: ${fmtMs(totalMs)}`)
  console.log(``)

  for (const m of [m1, m2, m3, m4, m5]) {
    console.log(`  ${m.name}  (${fmtMs(m.durationMs)})`)
    for (const t of m.evmTxs) {
      console.log(`    [EVM] ${t.label}`)
      console.log(`          gas: ${t.gasUsed.toLocaleString()}  price: ${ethers.formatUnits(t.gasPrice, 'gwei')} gwei  cost: ${t.costEth} ETH`)
    }
    for (const t of m.tronTxs) {
      const energyFeetrx    = (t.energyFee / 1_000_000).toFixed(6)
      const netFeetrx       = (t.netFee    / 1_000_000).toFixed(6)
      const bwFeeSun        = t.netFee - t.energyFee
      const bwFeeTrx        = (bwFeeSun / 1_000_000).toFixed(6)
      const bwAmount        = Math.round(bwFeeSun / 1_000)
      console.log(`    [TRX] ${t.label}`)
      console.log(`          energy: ${t.energyUsed.toLocaleString()}  energyFee: ${energyFeetrx} TRX`)
      console.log(`          bandwidth: ${bwAmount} units  bandwidthFee: ${bwFeeTrx} TRX  totalFee: ${netFeetrx} TRX`)
    }
  }
  console.log(`${'═'.repeat(60)}\n`)
}

main().catch((err) => { console.error(err); process.exitCode = 1 })
