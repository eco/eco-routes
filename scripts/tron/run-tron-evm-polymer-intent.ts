/**
 * run-tron-evm-polymer-intent.ts
 *
 * Full lifecycle for a Tron → EVM intent using the Polymer prover:
 *   1. Approve USDT + PublishAndFund on Tron: locks USDT reward in vault
 *   2. Approve USDC + FulfillAndProve on EVM (Base): solver fulfills + EVM PolymerProver
 *      emits IntentFulfilledFromSource(tronChainId, encodedProofs)
 *   3. Fetch cross-chain proof from Polymer JSON-RPC API:
 *        proof_request(srcChainId=Base, srcBlockNumber, globalLogIndex) → jobId
 *        proof_query(jobId) → base64 proof
 *   4. Submit proof to Tron PolymerProver.validate(bytes proof)
 *   5. Withdraw USDT reward on Tron
 *
 * Required env vars:
 *   PRIVATE_KEY           hex private key (with or without 0x)
 *   ALCHEMY_API_KEY       for Base RPC (or set EVM_RPC_URL directly)
 *   POLYMER_PROVER_API    Polymer JSON-RPC API base URL
 *   POLYMER_API_KEY       API key for Polymer (passed as Bearer token)
 *
 * Optional env vars (defaults to deployed mainnet addresses):
 *   EVM_RPC_URL                   override Base RPC URL
 *   EVM_PORTAL                    EVM portal address
 *   EVM_POLYMER_PROVER            EVM PolymerProver address
 *   TRON_RPC_URL                  (default: https://api.trongrid.io)
 *   TRON_PORTAL_HEX20             Tron portal hex20 address
 *   TRON_POLYMER_PROVER_HEX20     Tron PolymerProver hex20 address
 *   POLL_INTERVAL_SEC             (default: 30)
 *   POLL_TIMEOUT_MIN              (default: 60)
 *
 * Usage:
 *   set -a && source .env && set +a
 *   EVM_RPC_URL=https://base-mainnet.g.alchemy.com/v2/<key> \
 *   TRON_RPC_URL=https://api.trongrid.io \
 *   npx ts-node scripts/tron/run-tron-evm-polymer-intent.ts
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

const REWARD_AMOUNT = 100_000n  // 0.1 USDT  (6 decimals) — locked on Tron
const ROUTE_AMOUNT  = 100_000n  // 0.1 USDC  (6 decimals) — transferred on Base

const TRON_EXPLORER = 'https://tronscan.org/#/transaction'

// ─── Pricing assumptions (for USD cost estimates) ─────────────────────────────
const TRX_USD            = 0.32          // TRX price in USD
const ETH_USD            = 2_000         // ETH price in USD
const ENERGY_RENTAL      = 3.7 / 100_000 // TRX per energy unit (3.7 TRX per 100k)
const POLYMER_API_USD    = 0.01          // Polymer proof API cost (fixed)
// USDT base energies — factor affects only USDT calls; non-USDT energy is fixed
const USDT_BASE_EXISTING = 7_673         // USDT op base energy, existing slot (balanceOf > 0)
const USDT_BASE_NEW      = 22_664        // USDT op base energy, new slot (balanceOf = 0)
// Tron→EVM USDT total base: approve(existing) + vault(always new) + solver receive(always existing)
const TRON_EVM_USDT_BASE = USDT_BASE_EXISTING + USDT_BASE_NEW + USDT_BASE_EXISTING // 38_010

/** Keccak256 topic[0] of IntentFulfilledFromSource(uint64,bytes) */
const INTENT_FULFILLED_TOPIC = ethers.id('IntentFulfilledFromSource(uint64,bytes)')

// ─── ABIs / interfaces ────────────────────────────────────────────────────────

const ERC20_ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
  'function balanceOf(address) view returns (uint256)',
]

const POLYMER_PROVER_ABI = [
  'function validate(bytes calldata proof) external',
  'function provenIntents(bytes32) external view returns (tuple(address claimant, uint64 destination))',
]

const FULFILL_AND_PROVE_ABI = [
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

const TRANSFER_IFACE = new ethers.Interface(['function transfer(address to, uint256 amount) returns (bool)'])

// For encoding complex Tron calls via ethers ABI encoder + rawParameter
const PUBLISH_AND_FUND_IFACE = new ethers.Interface([
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
])

const PUBLISH_AND_FUND_SIG =
  'publishAndFund((uint64,(bytes32,uint64,address,uint256,(address,uint256)[],(address,bytes,uint256)[]),(uint64,address,address,uint256,(address,uint256)[])),bool)'

const BATCH_WITHDRAW_IFACE = new ethers.Interface(BATCH_WITHDRAW_ABI)
const BATCH_WITHDRAW_SIG =
  'batchWithdraw(uint64[],bytes32[],(uint64,address,address,uint256,(address,uint256)[])[])'

const VALIDATE_IFACE = new ethers.Interface(['function validate(bytes calldata proof) external'])
const VALIDATE_SIG = 'validate(bytes)'

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
    { feeLimit: 500_000_000, callValue, rawParameter },
    [],
  )
  if (!result.result?.result) throw new Error(`triggerSmartContract failed: ${JSON.stringify(result)}`)
  const signed    = await tw.trx.sign(result.transaction)
  const broadcast = await tw.trx.sendRawTransaction(signed)
  if (!broadcast.result) throw new Error(`Broadcast failed: ${JSON.stringify(broadcast)}`)
  const txid = broadcast.txid ?? (broadcast as any).transaction?.txID
  if (!txid) throw new Error(`No txid in broadcast response: ${JSON.stringify(broadcast)}`)
  for (let i = 0; i < 60; i++) {
    await sleep(5000)
    const info: any = await tw.trx.getTransactionInfo(txid)
    if (info?.id) {
      if (info.receipt?.result !== 'SUCCESS') throw new Error(`Tx reverted: ${JSON.stringify(info)}`)
      return { txid, info }
    }
  }
  throw new Error(`Timed out waiting for ${txid}`)
}

// ─── Step 1: Create and fund intent on Tron ───────────────────────────────────

async function createIntentOnTron(
  tw: TronWeb,
  tronPortalB58: string,
  tronPortalHex: string,
  tronPolymerProverHex: string,
  tronUsdtHex: string,
  evmPortal: string,
  evmUsdcAddr: string,
  evmChainId: number,
  recipient: string,   // EVM address to receive USDC (hex20)
): Promise<{
  intentHash: string
  routeHash: string
  rewardHash: string
  salt: string
  deadline: number
  txid: string
  metrics: StepMetrics
}> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 1 — Approve USDT + PublishAndFund on Tron`)
  console.log(`${'─'.repeat(60)}`)

  const t0 = Date.now()
  const metrics: StepMetrics = { name: 'Step 1: Create intent (Tron)', durationMs: 0, evmTxs: [], tronTxs: [] }

  const abiCoder    = ethers.AbiCoder.defaultAbiCoder()
  const deployerAddr  = tw.address.fromPrivateKey(tw.defaultPrivateKey as string) as string
  const deployerHex20 = '0x' + (tw.address.toHex(deployerAddr) as string).slice(2)
  const tronUsdtB58   = tw.address.fromHex('41' + tronUsdtHex.slice(2)) as string

  const deadline = Math.floor(Date.now() / 1000) + 24 * 60 * 60
  const salt     = ethers.keccak256(ethers.toUtf8Bytes(`eco-polymer-tron-evm-${Date.now()}`))

  // Route: execute on Base — transfer USDC to recipient
  const transferData = TRANSFER_IFACE.encodeFunctionData('transfer', [recipient, ROUTE_AMOUNT])
  const route = {
    salt,
    deadline:     BigInt(deadline),
    portal:       evmPortal,    // Base portal (EVM address — fine as address type in Tron ABI)
    nativeAmount: 0n,
    tokens: [{ token: evmUsdcAddr, amount: ROUTE_AMOUNT }],
    calls:  [{ target: evmUsdcAddr, data: transferData, value: 0n }],
  }

  // Reward: 0.1 USDT on Tron, proven by Tron PolymerProver
  const reward = {
    deadline:     BigInt(deadline),
    creator:      deployerHex20,
    prover:       tronPolymerProverHex,  // Tron PolymerProver validates proof on Tron
    nativeAmount: 0n,
    tokens: [{ token: tronUsdtHex, amount: REWARD_AMOUNT }],
  }

  const routeHash = ethers.keccak256(
    abiCoder.encode(
      ['tuple(bytes32 salt,uint64 deadline,address portal,uint256 nativeAmount,tuple(address token,uint256 amount)[] tokens,tuple(address target,bytes data,uint256 value)[] calls)'],
      [route],
    ),
  )
  const rewardHash = ethers.keccak256(
    abiCoder.encode(
      ['tuple(uint64 deadline,address creator,address prover,uint256 nativeAmount,tuple(address token,uint256 amount)[] tokens)'],
      [reward],
    ),
  )
  const intentHash = ethers.keccak256(
    ethers.solidityPacked(['uint64', 'bytes32', 'bytes32'], [BigInt(evmChainId), routeHash, rewardHash]),
  )

  console.log(`  Wallet:   ${deployerAddr} (${deployerHex20})`)
  console.log(`  Deadline: ${new Date(deadline * 1000).toISOString()}`)
  console.log(`  Reward:   0.1 USDT locked on Tron`)
  console.log(`  Want:     0.1 USDC → ${recipient} on Base`)
  console.log(`  intentHash: ${intentHash}`)

  // Approve USDT to portal
  console.log(`  Approving USDT to Tron portal...`)
  const { txid: approveTxid, info: approveInfo } = await tronSendAndWait(
    tw, tronUsdtB58, 'approve(address,uint256)',
    new ethers.Interface(['function approve(address,uint256)']).encodeFunctionData('approve', [tronPortalHex, REWARD_AMOUNT + 1n]).slice(10),
  )
  console.log(`  Approve txid: ${approveTxid}`)
  console.log(`  Approve receipt result: ${approveInfo.receipt?.result}`)
  metrics.tronTxs.push({
    label: 'approve USDT',
    energyUsed: approveInfo.receipt?.energy_usage_total ?? 0,
    energyFee:  approveInfo.receipt?.energy_fee ?? 0,
    netFee:     approveInfo.fee ?? 0,
    bandwidthUsed: approveInfo.receipt?.net_usage ?? 0,
  })

  // Verify on-chain allowance before proceeding — catches phantom txid scenarios
  // where sendRawTransaction reported success but the TX never landed.
  console.log(`  Verifying on-chain allowance...`)
  const allowanceResult: any = await (tw.transactionBuilder as any).triggerConstantContract(
    tronUsdtB58, 'allowance(address,address)',
    { rawParameter: abiCoder.encode(['address', 'address'], [deployerHex20, tronPortalHex]).slice(2) },
    [],
    deployerAddr,
  )
  const allowanceHex = allowanceResult?.constant_result?.[0] ?? '0'
  const onChainAllowance = BigInt('0x' + (allowanceHex || '0'))
  console.log(`  On-chain allowance: ${onChainAllowance} (need ${REWARD_AMOUNT})`)
  if (onChainAllowance < REWARD_AMOUNT) {
    throw new Error(
      `Approve TX ${approveTxid} confirmed but allowance is ${onChainAllowance}, ` +
      `expected >= ${REWARD_AMOUNT}. TX may not have landed on-chain.`,
    )
  }
  // TronGrid is load-balanced — the node that confirmed the approve may differ from
  // the one that simulates publishAndFund. Wait ~3 blocks so all nodes catch up.
  console.log(`  Allowance confirmed. Waiting for TronGrid node sync (~9s)...`)
  await sleep(9_000)

  // PublishAndFund on Tron — retry on CONTRACT_VALIDATE_ERROR in case a lagging
  // TronGrid node still simulates against pre-approve state.
  console.log(`  Sending publishAndFund on Tron...`)
  const intent   = { destination: evmChainId, route, reward }
  const calldata = PUBLISH_AND_FUND_IFACE.encodeFunctionData('publishAndFund', [intent, false])
  const { txid, info: fundInfo } = await tronSendAndWait(tw, tronPortalB58, PUBLISH_AND_FUND_SIG, calldata.slice(10))
  metrics.tronTxs.push({
    label: 'publishAndFund',
    energyUsed: fundInfo.receipt?.energy_usage_total ?? 0,
    energyFee:  fundInfo.receipt?.energy_fee ?? 0,
    netFee:     fundInfo.fee ?? 0,
    bandwidthUsed: fundInfo.receipt?.net_usage ?? 0,
  })
  console.log(`  done.  txid: ${txid}`)
  console.log(`  ${TRON_EXPLORER}/${txid}`)

  metrics.durationMs = Date.now() - t0
  return { intentHash, routeHash, rewardHash, salt, deadline, txid, metrics }
}

// ─── Step 2: Fulfill + prove on EVM ──────────────────────────────────────────

async function fulfillAndProveOnEvm(
  wallet: ethers.Wallet,
  evmPortal: string,
  evmPolymerProver: string,
  evmUsdcAddr: string,
  tronPortalHex: string,
  tronUsdtHex: string,
  tronChainId: number,
  intentHash: string,
  salt: string,
  deadline: number,
  rewardHash: string,
  recipient: string,
): Promise<{ txHash: string; blockNumber: number; globalLogIndex: number; metrics: StepMetrics }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 2 — Approve USDC + FulfillAndProve on Base`)
  console.log(`${'─'.repeat(60)}`)

  const t0 = Date.now()
  const metrics: StepMetrics = { name: 'Step 2: Fulfill + prove (Base)', durationMs: 0, evmTxs: [], tronTxs: [] }

  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  const transferData = TRANSFER_IFACE.encodeFunctionData('transfer', [recipient, ROUTE_AMOUNT])
  const route = {
    salt,
    deadline:     BigInt(deadline),
    portal:       evmPortal,
    nativeAmount: 0n,
    tokens: [{ token: evmUsdcAddr, amount: ROUTE_AMOUNT }],
    calls:  [{ target: evmUsdcAddr, data: transferData, value: 0n }],
  }

  const claimant = ethers.zeroPadValue(wallet.address, 32)

  // Approve USDC to portal
  console.log(`  Approving 0.1 USDC to Base portal...`)
  const usdc = new ethers.Contract(evmUsdcAddr, ERC20_ABI, wallet)
  const approveTx = await usdc.approve(evmPortal, ROUTE_AMOUNT)
  const approveReceipt = await approveTx.wait()
  metrics.evmTxs.push({
    label: 'approve USDC',
    gasUsed: approveReceipt.gasUsed,
    gasPrice: approveReceipt.gasPrice ?? approveReceipt.effectiveGasPrice ?? 0n,
    costEth: ethers.formatEther(approveReceipt.gasUsed * (approveReceipt.gasPrice ?? approveReceipt.effectiveGasPrice ?? 0n)),
  })

  // FulfillAndProve on Base
  console.log(`  Sending fulfillAndProve on Base...`)
  const portal = new ethers.Contract(evmPortal, FULFILL_AND_PROVE_ABI, wallet)
  const tx = await portal.fulfillAndProve(
    intentHash, route, rewardHash, claimant,
    evmPolymerProver,   // prover on destination chain (Base) — emits IntentFulfilledFromSource
    tronChainId,        // sourceChainDomainID = Tron chain ID (where rewards are)
    '0x',
  )
  const receipt = await tx.wait()
  metrics.evmTxs.push({
    label: 'fulfillAndProve',
    gasUsed: receipt.gasUsed,
    gasPrice: receipt.gasPrice ?? receipt.effectiveGasPrice ?? 0n,
    costEth: ethers.formatEther(receipt.gasUsed * (receipt.gasPrice ?? receipt.effectiveGasPrice ?? 0n)),
  })
  console.log(`  done.  tx: ${tx.hash}`)

  // Find IntentFulfilledFromSource log — its index is the globalLogIndex for Polymer
  const log = receipt.logs.find((l: any) => l.topics[0] === INTENT_FULFILLED_TOPIC)
  if (!log) throw new Error('IntentFulfilledFromSource event not found in receipt')
  const globalLogIndex = log.index

  console.log(`  blockNumber: ${receipt.blockNumber}  globalLogIndex: ${globalLogIndex}`)

  metrics.durationMs = Date.now() - t0
  return { txHash: tx.hash, blockNumber: receipt.blockNumber, globalLogIndex, metrics }
}

// ─── Step 3: Fetch proof from Polymer API ─────────────────────────────────────

async function fetchPolymerProof(
  apiBase: string,
  apiKey: string,
  evmChainId: number,
  srcBlockNumber: number,
  globalLogIndex: number,
  intervalSec: number,
  timeoutMin: number,
): Promise<{ proofHex: string; metrics: StepMetrics }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 3 — Fetch Polymer cross-chain proof`)
  console.log(`${'─'.repeat(60)}`)
  console.log(`  srcChainId:     ${evmChainId}`)
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

  const jobId = await rpc('proof_request', [{
    srcChainId:     evmChainId,
    srcBlockNumber,
    globalLogIndex,
  }])
  console.log(`  jobId: ${jobId}`)

  const polls = Math.ceil((timeoutMin * 60) / intervalSec)
  for (let i = 1; i <= polls; i++) {
    await sleep(intervalSec * 1000)
    const result = await rpc('proof_query', [jobId])
    console.log(`  [${i}/${polls}] status: ${result?.status ?? 'pending'}`)
    if (result?.status === 'complete') {
      const proofBytes = Buffer.from(result.proof as string, 'base64')
      const proofHex   = '0x' + proofBytes.toString('hex')
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

// ─── Step 4: Validate proof on Tron ──────────────────────────────────────────

async function validateOnTron(
  tw: TronWeb,
  tronPolymerProverB58: string,
  intentHash: string,
  proofHex: string,
): Promise<{ txid: string; metrics: StepMetrics }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 4 — Submit proof to Tron PolymerProver.validate()`)
  console.log(`${'─'.repeat(60)}`)

  const t0 = Date.now()
  const metrics: StepMetrics = { name: 'Step 4: Validate proof (Tron)', durationMs: 0, evmTxs: [], tronTxs: [] }

  console.log(`  Sending validate()...`)
  const calldata = VALIDATE_IFACE.encodeFunctionData('validate', [proofHex])
  const { txid, info } = await tronSendAndWait(
    tw, tronPolymerProverB58, VALIDATE_SIG, calldata.slice(10),
  )
  metrics.tronTxs.push({
    label: 'validate',
    energyUsed: info.receipt?.energy_usage_total ?? 0,
    energyFee:  info.receipt?.energy_fee ?? 0,
    netFee:     info.fee ?? 0,
    bandwidthUsed: info.receipt?.net_usage ?? 0,
  })
  console.log(`  done.  txid: ${txid}`)
  console.log(`  ${TRON_EXPLORER}/${txid}`)

  // Verify intent is now proven — query provenIntents via call
  // (TronWeb triggerConstantContract for view calls)
  const provenData = await (tw.transactionBuilder as any).triggerConstantContract(
    tronPolymerProverB58,
    'provenIntents(bytes32)',
    {},
    [{ type: 'bytes32', value: intentHash }],
  )
  console.log(`  provenIntents raw: ${provenData?.constant_result?.[0]}`)

  metrics.durationMs = Date.now() - t0
  return { txid, metrics }
}

// ─── Step 5: Withdraw USDT reward on Tron ────────────────────────────────────

async function withdrawOnTron(
  tw: TronWeb,
  tronPortalB58: string,
  tronPortalHex: string,
  tronPolymerProverHex: string,
  tronUsdtHex: string,
  evmChainId: number,
  routeHash: string,
  deadline: number,
): Promise<{ txid: string; metrics: StepMetrics }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 5 — Withdraw USDT reward on Tron`)
  console.log(`${'─'.repeat(60)}`)

  const t0 = Date.now()
  const metrics: StepMetrics = { name: 'Step 5: Withdraw USDT (Tron)', durationMs: 0, evmTxs: [], tronTxs: [] }

  const deployerAddr  = tw.address.fromPrivateKey(tw.defaultPrivateKey as string) as string
  const deployerHex20 = '0x' + (tw.address.toHex(deployerAddr) as string).slice(2)

  const reward = [
    BigInt(deadline),
    deployerHex20,
    tronPolymerProverHex,
    0n,
    [{ token: tronUsdtHex, amount: REWARD_AMOUNT }],
  ]

  const calldata = BATCH_WITHDRAW_IFACE.encodeFunctionData('batchWithdraw', [
    [evmChainId], [routeHash], [reward],
  ])

  console.log(`  Sending batchWithdraw on Tron...`)
  const { txid, info } = await tronSendAndWait(
    tw, tronPortalB58, BATCH_WITHDRAW_SIG, calldata.slice(10),
  )
  metrics.tronTxs.push({
    label: 'batchWithdraw',
    energyUsed: info.receipt?.energy_usage_total ?? 0,
    energyFee:  info.receipt?.energy_fee ?? 0,
    netFee:     info.fee ?? 0,
    bandwidthUsed: info.receipt?.net_usage ?? 0,
  })
  console.log(`  done.  txid: ${txid}`)
  console.log(`  ${TRON_EXPLORER}/${txid}`)

  metrics.durationMs = Date.now() - t0
  return { txid, metrics }
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
  const tw = new TronWeb({
    fullHost: tronRpcUrl,
    privateKey: pk,
    ...(tronGridKey ? { headers: { 'TRON-PRO-API-KEY': tronGridKey } } : {}),
  })

  const { chainId: evmChainIdBig } = await provider.getNetwork()
  const evmChainId  = Number(evmChainIdBig)
  const tronChainId = tronChainIdFromRpcUrl(tronRpcUrl)

  const chainName = EVM_CHAIN_NAMES[evmChainId] ?? `chain-${evmChainId}`
  const explorer  = evmExplorer(evmChainIdBig)

  // Tron portal
  let tronPortalHex = process.env.TRON_PORTAL_HEX20 ?? ''
  if (!tronPortalHex) {
    const b58 = process.env.TRON_PORTAL_CONTRACT ?? ''
    if (!b58) throw new Error('TRON_PORTAL_HEX20 or TRON_PORTAL_CONTRACT not set')
    tronPortalHex = '0x' + (tw.address.toHex(b58) as string).slice(2)
  }
  const tronPortalB58         = tw.address.fromHex('41' + tronPortalHex.slice(2)) as string
  const tronPolymerProverB58  = tw.address.fromHex('41' + tronProverHex.slice(2)) as string

  const evmUsdcAddr = EVM_USDC_BY_CHAIN[evmChainId]
  if (!evmUsdcAddr) throw new Error(`No USDC address configured for EVM chain ${evmChainId}`)
  const tronUsdtHex = TRON_USDT_HEX_BY_CHAIN[tronChainId]
  if (!tronUsdtHex) throw new Error(`No USDT address configured for Tron chain ${tronChainId}`)

  // EVM recipient defaults to the wallet address
  const evmRecipient = process.env.EVM_RECIPIENT ?? wallet.address

  console.log(`\n${'═'.repeat(60)}`)
  console.log(`  Tron → EVM  |  Polymer Prover  |  Tron → ${chainName}`)
  console.log(`  Reward:  0.1 USDT locked on Tron`)
  console.log(`  Want:    0.1 USDC → ${evmRecipient} on ${chainName}`)
  console.log(`  Wallet:  ${wallet.address}`)
  console.log(`${'═'.repeat(60)}`)

  const totalStart = Date.now()

  // ── Step 1 ──
  const { intentHash, routeHash, rewardHash, salt, deadline, txid: createTxid, metrics: m1 } =
    await createIntentOnTron(
      tw, tronPortalB58, tronPortalHex, tronProverHex,
      tronUsdtHex, evmPortal, evmUsdcAddr, evmChainId, evmRecipient,
    )

  // ── Step 2 ──
  const { txHash: fulfillTx, blockNumber, globalLogIndex, metrics: m2 } =
    await fulfillAndProveOnEvm(
      wallet, evmPortal, evmPolymerProver, evmUsdcAddr,
      tronPortalHex, tronUsdtHex, tronChainId,
      intentHash, salt, deadline, rewardHash, evmRecipient,
    )

  // ── Step 3 ──
  const { proofHex: proof, metrics: m3 } = await fetchPolymerProof(
    polymerApiBase, polymerApiKey, evmChainId,
    blockNumber, globalLogIndex,
    pollInterval, pollTimeout,
  )

  // ── Step 4 ──
  const { txid: validateTxid, metrics: m4 } =
    await validateOnTron(tw, tronPolymerProverB58, intentHash, proof)

  // ── Step 5 ──
  const { txid: withdrawTxid, metrics: m5 } =
    await withdrawOnTron(
      tw, tronPortalB58, tronPortalHex, tronProverHex,
      tronUsdtHex, evmChainId, routeHash, deadline,
    )

  const totalMs = Date.now() - totalStart

  // ── Summary ──
  console.log(`\n${'═'.repeat(60)}`)
  console.log(`  SUMMARY`)
  console.log(`${'═'.repeat(60)}`)
  console.log(`  Route:        Tron → ${chainName} (Polymer)`)
  console.log(`  Intent:       ${intentHash}`)
  console.log(`  Block:        ${blockNumber}  logIndex: ${globalLogIndex}`)
  console.log(``)
  console.log(`  1. Create:    ${TRON_EXPLORER}/${createTxid}`)
  console.log(`  2. Fulfill:   ${explorer}/tx/${fulfillTx}`)
  console.log(`  4. Validate:  ${TRON_EXPLORER}/${validateTxid}`)
  console.log(`  5. Withdraw:  ${TRON_EXPLORER}/${withdrawTxid}`)

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

  let totalUsd = 0

  for (const m of [m1, m2, m3, m4, m5]) {
    console.log(`  ${m.name}  (${fmtMs(m.durationMs)})`)
    for (const t of m.evmTxs) {
      const usd = parseFloat(t.costEth) * ETH_USD
      totalUsd += usd
      console.log(`    [EVM] ${t.label}`)
      console.log(`          gas: ${t.gasUsed.toLocaleString()}  price: ${ethers.formatUnits(t.gasPrice, 'gwei')} gwei  cost: ${t.costEth} ETH  ≈ $${usd.toFixed(4)}`)
    }
    for (const t of m.tronTxs) {
      const energyFeetrx    = (t.energyFee / 1_000_000).toFixed(6)
      const netFeetrx       = (t.netFee    / 1_000_000).toFixed(6)
      const bwFeeSun        = t.netFee - t.energyFee
      const bwFeeTrx        = (bwFeeSun / 1_000_000).toFixed(6)
      const bwAmount        = Math.round(bwFeeSun / 1_000)
      const rentalTrx       = t.energyUsed * ENERGY_RENTAL
      const usd             = (rentalTrx + bwFeeSun / 1_000_000) * TRX_USD
      totalUsd += usd
      console.log(`    [TRX] ${t.label}`)
      console.log(`          energy: ${t.energyUsed.toLocaleString()}  energyFee: ${energyFeetrx} TRX  rental: ${rentalTrx.toFixed(4)} TRX`)
      console.log(`          bandwidth: ${bwAmount} units  bandwidthFee: ${bwFeeTrx} TRX  totalFee: ${netFeetrx} TRX  ≈ $${usd.toFixed(4)}`)
    }
  }
  totalUsd += POLYMER_API_USD

  console.log(``)
  console.log(`  Polymer API fee:       $${POLYMER_API_USD.toFixed(2)}`)
  console.log(`  Total cost (rental):   $${totalUsd.toFixed(4)}`)
  console.log(`${'═'.repeat(60)}`)

  // ─── Cost range analysis ──────────────────────────────────────────────────────
  // No variable slots: approve=existing, vault=always new, solver receive=always existing
  // validate() has no USDT ops — its energy is entirely in fixedNonUsdt
  const tronTxsAll     = [...m1.tronTxs, ...m4.tronTxs, ...m5.tronTxs]
  const detectedFactor = tronTxsAll[0].energyUsed / USDT_BASE_EXISTING - 1  // from approve
  const totalObsEnergy = tronTxsAll.reduce((s, t) => s + t.energyUsed, 0)
  const totalObsBwSun  = tronTxsAll.reduce((s, t) => s + (t.netFee - t.energyFee), 0)

  const fixedNonUsdt = totalObsEnergy - Math.round(TRON_EVM_USDT_BASE * (1 + detectedFactor))

  const calcCost = (f: number): number => {
    const energy = fixedNonUsdt + Math.round(TRON_EVM_USDT_BASE * (1 + f))
    return (energy * ENERGY_RENTAL + totalObsBwSun / 1_000_000) * TRX_USD + POLYMER_API_USD
  }

  console.log(`\n${'═'.repeat(60)}`)
  console.log(`  COST RANGE`)
  console.log(`  This run: factor ${detectedFactor.toFixed(2)} (max 3.4) · all slots fixed`)
  console.log(`  Assumptions: rental 3.7 TRX/100k · approval always existing · vault always new`)
  console.log(`    · solver receive always existing · bandwidth 1 TRX/1,000 · Polymer API $0.01`)
  console.log(`    · TRX $${TRX_USD} · ETH $${ETH_USD}`)
  const atBest  = detectedFactor <= 0.05
  const atWorst = Math.abs(detectedFactor - 3.4) < 0.05
  console.log(`${'═'.repeat(60)}`)
  console.log(`  Best  (factor 0.0):  $${calcCost(0).toFixed(2)}${atBest ? '  ← this run' : ''}`)
  console.log(`  Worst (factor 3.4):  $${calcCost(3.4).toFixed(2)}${atWorst ? '  ← this run' : ''}`)
  if (!atBest && !atWorst) {
    console.log(`  This run (factor ${detectedFactor.toFixed(2)}):  $${calcCost(detectedFactor).toFixed(2)}  ← this run`)
  }
  console.log(`${'═'.repeat(60)}\n`)
}

main().catch((err) => { console.error(err); process.exitCode = 1 })
