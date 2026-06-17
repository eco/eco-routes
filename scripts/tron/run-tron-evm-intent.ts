/**
 * run-tron-evm-intent.ts
 *
 * Full lifecycle for a Tron → EVM intent:
 *   1. Approve + PublishAndFund intent on Tron (source): reward = 0.1 USDT locked on Tron
 *   2. Approve USDC + FulfillAndProve on EVM (destination): sends 0.05 USDC to creator, LZ proof → Tron
 *   3. Poll Tron prover until proof arrives
 *   4. Withdraw USDT reward on Tron
 *
 * Required env vars:
 *   PRIVATE_KEY   - hex private key (with or without 0x)
 *   EVM_RPC_URL   - RPC endpoint for the destination EVM chain
 *
 * Optional env vars (defaults to standard deployed addresses):
 *   TRON_RPC_URL          (default: https://api.trongrid.io — mainnet)
 *   TRON_PORTAL_HEX20     (default: 0xbbe65c636a745ccb12fb0a8376f5ed089a86983a)
 *   TRON_LZ_PROVER_HEX20  (default: 0xf8b5348d6e1e4c47de4abc2d9946963a7a37f2c8)
 *   EVM_PORTAL            (default: 0x399Dbd5DF04f83103F77A58cBa2B7c4d3cdede97)
 *   EVM_LZ_PROVER         (default: 0xf64eaca0D1cF874ea34b8E73127f0Fe535c6be41)
 *   POLL_INTERVAL_SEC     (default: 30)  — seconds between proof polls
 *   POLL_TIMEOUT_MIN      (default: 60)  — minutes before giving up
 *
 * Chain IDs are detected automatically from the RPC endpoints at startup.
 * EIDs are resolved from docs/lzDeployments.json using those chain IDs.
 * Token addresses are resolved from the hardcoded maps below.
 *
 * Usage:
 *   set -a && source .env && set +a
 *   EVM_RPC_URL=https://mainnet.base.org \
 *     npx ts-node scripts/tron/run-tron-evm-intent.ts
 */

import * as fs from 'fs'
import * as path from 'path'
import { TronWeb } from 'tronweb'
import { ethers } from 'ethers'
import 'dotenv/config'

// ─── Token addresses ──────────────────────────────────────────────────────────

// USDC (or equivalent stablecoin) by EVM chain ID
const EVM_USDC_BY_CHAIN: Record<number, string> = {
  1:        '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', // Ethereum mainnet
  10:       '0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85', // Optimism
  137:      '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359', // Polygon
  8453:     '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', // Base
  42161:    '0xaf88d065e77c8cC2239327C5EDb3A432268e5831', // Arbitrum One
  84532:    '0x036CbD53842c5426634e7929541eC2318f3dCF7e', // Base Sepolia
  11155111: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238', // Ethereum Sepolia
}

// USDT hex20 address by Tron chain ID
const TRON_USDT_HEX_BY_CHAIN: Record<number, string> = {
  728126428:  '0xa614f803b6fd780986a42c78ec9c7f77e6ded13c', // Tron mainnet   (TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t)
  2494104990: '0xc060ca2c712ba701f9663750ff447fb7b48e42f1', // Tron Shasta    (TTWQgxc52wHxuuG9sy2D7XFkNcSSzKK7ZB)
}

// Human-readable names for display
const EVM_CHAIN_NAMES: Record<number, string> = {
  1:        'Ethereum',
  10:       'Optimism',
  137:      'Polygon',
  8453:     'Base',
  42161:    'Arbitrum',
  84532:    'Base Sepolia',
  11155111: 'Ethereum Sepolia',
}

// ─── LZ EID resolution ────────────────────────────────────────────────────────

function loadLzDeployments(): any {
  const p = path.join(__dirname, '../..', 'docs', 'lzDeployments.json')
  return JSON.parse(fs.readFileSync(p, 'utf8'))
}

function eidFromNativeChainId(nativeChainId: number): number {
  const data = loadLzDeployments()
  for (const key of Object.keys(data)) {
    const chain = data[key]
    if (Number(chain.chainDetails?.nativeChainId) !== nativeChainId) continue
    const dep = chain.deployments?.find((d: any) => d.version === 2)
    if (dep?.eid) return Number(dep.eid)
  }
  throw new Error(`No LZ v2 EID found for native chain ID ${nativeChainId}`)
}

// Tron chain ID inferred from the RPC host — no on-chain query needed
function tronChainIdFromRpcUrl(url: string): number {
  if (url.includes('shasta')) return 2494104990  // Tron Shasta testnet
  if (url.includes('nile'))   return 3448148188   // Tron Nile testnet
  return 728126428                                // Tron mainnet
}

// ─── Constants ────────────────────────────────────────────────────────────────

const TRON_EXPLORER  = 'https://tronscan.org/#/transaction'
const REWARD_AMOUNT  = 100_000n  // 0.1 USDT (6 decimals) — locked on Tron as reward
const ROUTE_AMOUNT   =  50_000n  // 0.05 USDT (6 decimals) — solver provides on EVM

// ─── Pricing assumptions (for USD cost estimates) ─────────────────────────────
const TRX_USD            = 0.32           // TRX price in USD
const ETH_USD            = 2_000          // ETH price in USD
const ENERGY_RENTAL      = 3.7 / 100_000  // TRX per energy unit (3.7 TRX per 100k)
// USDT base energies — used to detect energy factor and compute range
// factor affects only USDT calls; non-USDT energy is fixed
const USDT_BASE_EXISTING = 7_673          // USDT op base energy, existing slot (balanceOf > 0)
const USDT_BASE_NEW      = 22_664         // USDT op base energy, new slot (balanceOf = 0)
// Tron→EVM USDT total base: approve(existing) + vault(always new) + solver receive(always existing)
const TRON_EVM_USDT_BASE = USDT_BASE_EXISTING + USDT_BASE_NEW + USDT_BASE_EXISTING // 38_010

// ─── ABIs ─────────────────────────────────────────────────────────────────────

const TRON_PUBLISH_AND_FUND_ABI = [
  {
    type: 'function', name: 'publishAndFund',
    inputs: [
      {
        name: 'intent', type: 'tuple', components: [
          { name: 'destination', type: 'uint64' },
          { name: 'route', type: 'tuple', components: [
            { name: 'salt', type: 'bytes32' },
            { name: 'deadline', type: 'uint64' },
            { name: 'portal', type: 'address' },
            { name: 'nativeAmount', type: 'uint256' },
            { name: 'tokens', type: 'tuple[]', components: [{ name: 'token', type: 'address' }, { name: 'amount', type: 'uint256' }] },
            { name: 'calls', type: 'tuple[]', components: [{ name: 'target', type: 'address' }, { name: 'data', type: 'bytes' }, { name: 'value', type: 'uint256' }] },
          ]},
          { name: 'reward', type: 'tuple', components: [
            { name: 'deadline', type: 'uint64' },
            { name: 'creator', type: 'address' },
            { name: 'prover', type: 'address' },
            { name: 'nativeAmount', type: 'uint256' },
            { name: 'tokens', type: 'tuple[]', components: [{ name: 'token', type: 'address' }, { name: 'amount', type: 'uint256' }] },
          ]},
        ],
      },
      { name: 'allowPartial', type: 'bool' },
    ],
    outputs: [{ name: 'intentHash', type: 'bytes32' }, { name: 'vault', type: 'address' }],
    stateMutability: 'payable',
  },
]

const TRON_WITHDRAW_ABI = [
  {
    type: 'function', name: 'batchWithdraw',
    inputs: [
      { name: 'destinations', type: 'uint64[]' },
      { name: 'routeHashes', type: 'bytes32[]' },
      { name: 'rewards', type: 'tuple[]', components: [
        { name: 'deadline', type: 'uint64' },
        { name: 'creator', type: 'address' },
        { name: 'prover', type: 'address' },
        { name: 'nativeAmount', type: 'uint256' },
        { name: 'tokens', type: 'tuple[]', components: [{ name: 'token', type: 'address' }, { name: 'amount', type: 'uint256' }] },
      ]},
    ],
    outputs: [], stateMutability: 'nonpayable',
  },
]

const EVM_FULFILL_AND_PROVE_ABI = [
  `function fulfillAndProve(
    bytes32 intentHash,
    tuple(bytes32 salt, uint64 deadline, address portal, uint256 nativeAmount,
          tuple(address token, uint256 amount)[] tokens,
          tuple(address target, bytes data, uint256 value)[] calls) route,
    bytes32 rewardHash,
    bytes32 claimant,
    address prover,
    uint64 sourceChainDomainID,
    bytes data
  ) external payable returns (bytes[] memory)`,
  `function fetchFee(uint64 domainID, bytes encodedProofs, bytes data) external view returns (uint256)`,
]

const ERC20_ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
]

const ERC20_IFACE        = new ethers.Interface(ERC20_ABI)
const ERC20_TRANSFER_IFACE = new ethers.Interface(['function transfer(address to, uint256 amount) returns (bool)'])

const TRON_PUBLISH_AND_FUND_SIG =
  'publishAndFund((uint64,(bytes32,uint64,address,uint256,(address,uint256)[],(address,bytes,uint256)[]),(uint64,address,address,uint256,(address,uint256)[])),bool)'

const TRON_WITHDRAW_SIG =
  'batchWithdraw(uint64[],bytes32[],(uint64,address,address,uint256,(address,uint256)[])[])'

const TRON_ERC20_APPROVE_SIG = 'approve(address,uint256)'

// ─── Metrics ─────────────────────────────────────────────────────────────────

interface StepMetrics {
  name: string
  durationMs: number
  evmTxs: { label: string; gasUsed: bigint; gasPrice: bigint; costEth: string }[]
  tronTxs: { label: string; energyUsed: number; energyFee: number; netFee: number }[]
}

function tronTxMetrics(label: string, info: any) {
  return {
    label,
    energyUsed: info.receipt?.energy_usage_total ?? 0,
    energyFee:  info.receipt?.energy_fee ?? 0,
    netFee:     info.fee ?? 0,
  }
}

function evmTxMetrics(label: string, receipt: any) {
  const gasPrice = receipt.gasPrice ?? receipt.effectiveGasPrice ?? 0n
  return {
    label,
    gasUsed:  receipt.gasUsed,
    gasPrice,
    costEth:  ethers.formatEther(receipt.gasUsed * gasPrice),
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms))

function getEvmExplorer(chainId: bigint): string {
  const explorers: Record<string, string> = {
    '1':     'https://etherscan.io',
    '10':    'https://optimistic.etherscan.io',
    '137':   'https://polygonscan.com',
    '8453':  'https://basescan.org',
    '42161': 'https://arbiscan.io',
  }
  return explorers[chainId.toString()] ?? 'https://etherscan.io'
}

function buildLzData(abiCoder: ethers.AbiCoder, receiverHex: string): string {
  const sourceChainProver = ethers.zeroPadValue(receiverHex, 32)
  const gasLimit = 200_000n
  return abiCoder.encode(
    ['tuple(bytes32 sourceChainProver, uint256 gasLimit)'],
    [{ sourceChainProver, gasLimit }],
  )
}

async function tronSendAndWait(
  tw: TronWeb,
  contractB58: string,
  funcSig: string,
  rawParameter: string,
  callValue = 0,
): Promise<any> {
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
      if (info.receipt?.result !== 'SUCCESS') throw new Error(`Tx failed: ${JSON.stringify(info)}`)
      return { txid, info }
    }
  }
  throw new Error(`Timed out waiting for ${txid}`)
}

// ─── Step 1: Approve USDT + PublishAndFund intent on Tron ─────────────────────

async function createIntent(
  tw: TronWeb,
  tronPortalB58: string,
  tronPortalHex: string,
  tronProverHex: string,
  tronUsdtHex: string,
  evmPortalHex: string,
  evmUsdcAddr: string,
  evmChainId: number,
  chainName: string,
): Promise<{ intentHash: string; salt: string; deadline: number; creatorHex: string; txId: string; metrics: StepMetrics }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 1 — Approve USDC + PublishAndFund intent on Tron → ${chainName}`)
  console.log(`${'─'.repeat(60)}`)

  const t0 = Date.now()
  const metrics: StepMetrics = { name: 'Step 1: Create intent (Tron)', durationMs: 0, evmTxs: [], tronTxs: [] }

  const deployerTronAddr = tw.address.fromPrivateKey(tw.defaultPrivateKey as string) as string
  const creatorHex = '0x' + (tw.address.toHex(deployerTronAddr) as string).slice(2)

  const deadline = Math.floor(Date.now() / 1000) + 24 * 60 * 60
  const salt = ethers.keccak256(ethers.toUtf8Bytes(`eco-routes-tron-${chainName}-${Date.now()}`))

  // Encode EVM-side route.calls: Executor transfers 0.05 USDC to creator
  const transferData = ERC20_TRANSFER_IFACE.encodeFunctionData('transfer', [creatorHex, ROUTE_AMOUNT])

  const intent = [
    evmChainId,
    // route: what solver must do on EVM — provide 0.05 USDC, Executor transfers it to creator
    [
      salt, deadline, evmPortalHex, 0,
      [{ token: evmUsdcAddr, amount: ROUTE_AMOUNT }],          // route.tokens: solver pre-approves USDC to EVM portal
      [{ target: evmUsdcAddr, data: transferData, value: 0 }], // route.calls: Executor sends USDC to creator
    ],
    // reward: 0.1 USDT locked on Tron for the solver
    [deadline, creatorHex, tronProverHex, 0, [{ token: tronUsdtHex, amount: REWARD_AMOUNT }]],
  ]

  console.log(`  Creator:   ${deployerTronAddr} (${creatorHex})`)
  console.log(`  Deadline:  ${new Date(deadline * 1000).toISOString()}`)
  console.log(`  Reward:    0.1 USDT (${tronUsdtHex}) locked on Tron`)
  console.log(`  Want:      0.05 USDC (${evmUsdcAddr}) sent to creator on ${chainName}`)

  // 1a. Approve Tron USDT to portal (needed for publishAndFund to pull tokens into vault)
  console.log(`  Approving 0.1 USDC to Tron portal...`)
  const tronUsdcB58 = tw.address.fromHex('41' + tronUsdtHex.slice(2)) as string
  const approveCalldata = ERC20_IFACE.encodeFunctionData('approve', [tronPortalHex, REWARD_AMOUNT + 1n])
  const { info: approveInfo } = await tronSendAndWait(tw, tronUsdcB58, TRON_ERC20_APPROVE_SIG, approveCalldata.slice(10))
  metrics.tronTxs.push(tronTxMetrics('approve USDT', approveInfo))
  console.log(`  Approved.`)

  // 1b. PublishAndFund
  console.log(`  Sending publishAndFund...`)
  const iface = new ethers.Interface(TRON_PUBLISH_AND_FUND_ABI)
  const calldata = iface.encodeFunctionData('publishAndFund', [intent, false])

  const { txid, info } = await tronSendAndWait(tw, tronPortalB58, TRON_PUBLISH_AND_FUND_SIG, calldata.slice(10))
  metrics.tronTxs.push(tronTxMetrics('publishAndFund', info))

  const topic = ethers.id('IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])')
  let intentHash = ''
  for (const log of info.log || []) {
    if (log.topics?.[0] === topic.slice(2)) { intentHash = '0x' + log.topics[1]; break }
  }
  if (!intentHash) throw new Error('IntentPublished event not found')

  metrics.durationMs = Date.now() - t0
  console.log(`  done. Intent hash: ${intentHash}`)
  return { intentHash, salt, deadline, creatorHex, txId: txid, metrics }
}

// ─── Step 2: Approve USDC + FulfillAndProve on EVM ────────────────────────────

async function fulfillAndProveOnEvm(
  wallet: ethers.Wallet,
  evmPortal: string,
  evmProver: string,
  evmUsdcAddr: string,
  tronPortal: string,
  tronProver: string,
  tronUsdtHex: string,
  tronEid: bigint,
  intentHash: string,
  salt: string,
  deadline: number,
  creatorHex: string,
): Promise<{ txHash: string; lzFeeEth: string; metrics: StepMetrics }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 2 — Approve USDC + FulfillAndProve on EVM`)
  console.log(`${'─'.repeat(60)}`)

  const t0 = Date.now()
  const metrics: StepMetrics = { name: 'Step 2: Fulfill + prove (EVM)', durationMs: 0, evmTxs: [], tronTxs: [] }

  const abiCoder = ethers.AbiCoder.defaultAbiCoder()
  const provider = wallet.provider!

  // Encode the same transfer call that was put in route.calls at publish time
  const transferData = ERC20_TRANSFER_IFACE.encodeFunctionData('transfer', [creatorHex, ROUTE_AMOUNT])

  const route = {
    salt,
    deadline: BigInt(deadline),
    portal: evmPortal,
    nativeAmount: 0n,
    tokens: [{ token: evmUsdcAddr, amount: ROUTE_AMOUNT }],
    calls:  [{ target: evmUsdcAddr, data: transferData, value: 0n }],
  }
  const reward = {
    deadline: BigInt(deadline),
    creator: creatorHex,
    prover: tronProver,
    nativeAmount: 0n,
    tokens: [{ token: tronUsdtHex, amount: REWARD_AMOUNT }],
  }

  const rewardHash = ethers.keccak256(
    abiCoder.encode(
      ['tuple(uint64 deadline, address creator, address prover, uint256 nativeAmount, tuple(address token, uint256 amount)[] tokens)'],
      [reward],
    ),
  )
  const claimant = ethers.zeroPadValue(wallet.address, 32)
  const encodedProofs = ethers.concat([intentHash, claimant])
  const lzData = buildLzData(abiCoder, tronProver)

  const proverContract = new ethers.Contract(evmProver, EVM_FULFILL_AND_PROVE_ABI, provider)
  const fee: bigint = await proverContract.fetchFee(tronEid, encodedProofs, lzData)
  console.log(`  LZ fee: ${ethers.formatEther(fee)} ETH`)

  // Approve USDC to portal so the portal can pull it into the Executor
  console.log(`  Approving 0.05 USDC to EVM portal...`)
  const usdc = new ethers.Contract(evmUsdcAddr, ERC20_ABI, wallet)
  const approveTx = await usdc.approve(evmPortal, ROUTE_AMOUNT)
  metrics.evmTxs.push(evmTxMetrics('approve USDC', await approveTx.wait()))
  console.log(`  Approved.`)

  console.log(`  sending fulfillAndProve...`)
  const portal = new ethers.Contract(evmPortal, EVM_FULFILL_AND_PROVE_ABI, wallet)
  const tx = await portal.fulfillAndProve(
    intentHash, route, rewardHash, claimant,
    evmProver, tronEid, lzData,
    { value: fee * 2n }, // 2x buffer — overage is refunded by LZ endpoint
  )
  metrics.evmTxs.push(evmTxMetrics('fulfillAndProve', await tx.wait()))
  metrics.durationMs = Date.now() - t0
  console.log(`  done.`)
  return { txHash: tx.hash, lzFeeEth: ethers.formatEther(fee), metrics }
}

// ─── Step 3: Poll Tron prover for proof ───────────────────────────────────────

async function pollForProof(
  tw: TronWeb,
  tronProverHex: string,
  intentHash: string,
  intervalSec: number,
  timeoutMin: number,
): Promise<StepMetrics> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 3 — Polling Tron prover for proof (timeout: ${timeoutMin}m)`)
  console.log(`${'─'.repeat(60)}`)

  const t0 = Date.now()
  const tronProverB58 = tw.address.fromHex('41' + tronProverHex.slice(2)) as string
  const polls = Math.ceil((timeoutMin * 60) / intervalSec)

  for (let i = 1; i <= polls; i++) {
    const result: any = await tw.transactionBuilder.triggerConstantContract(
      tronProverB58, 'provenIntents(bytes32)',
      { rawParameter: intentHash.slice(2).padStart(64, '0') },
      [],
      tw.defaultAddress.hex as string,
    )
    const raw = result?.constant_result?.[0] ?? ''
    // provenIntents returns ProofData{address claimant, uint64 destination} = 128 hex chars
    // claimant is in the first 64 chars (right-aligned address); non-zero means proof arrived
    const claimantWord = raw.slice(0, 64)
    if (claimantWord && claimantWord !== '0'.repeat(64)) {
      console.log(`  Proof arrived!`)
      return { name: 'Step 3: Wait for LZ proof (Tron)', durationMs: Date.now() - t0, evmTxs: [], tronTxs: [] }
    }
    console.log(`  [${i}/${polls}] waiting ${intervalSec}s...`)
    await sleep(intervalSec * 1000)
  }
  throw new Error(`Proof did not arrive within ${timeoutMin} minutes`)
}

// ─── Step 4: Withdraw USDT on Tron ────────────────────────────────────────────

async function withdrawOnTron(
  tw: TronWeb,
  tronPortalB58: string,
  tronProverHex: string,
  tronUsdtHex: string,
  evmPortalHex: string,
  evmUsdcAddr: string,
  evmChainId: number,
  salt: string,
  deadline: number,
  creatorHex: string,
): Promise<{ txId: string; metrics: StepMetrics }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 4 — Withdraw USDT on Tron`)
  console.log(`${'─'.repeat(60)}`)

  const t0 = Date.now()
  const metrics: StepMetrics = { name: 'Step 4: Withdraw USDT (Tron)', durationMs: 0, evmTxs: [], tronTxs: [] }

  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  // Reconstruct the exact same route that was published
  const transferData = ERC20_TRANSFER_IFACE.encodeFunctionData('transfer', [creatorHex, ROUTE_AMOUNT])
  const route = {
    salt,
    deadline: BigInt(deadline),
    portal: evmPortalHex,
    nativeAmount: 0n,
    tokens: [{ token: evmUsdcAddr, amount: ROUTE_AMOUNT }] as any[],
    calls:  [{ target: evmUsdcAddr, data: transferData, value: 0n }] as any[],
  }
  const routeHash = ethers.keccak256(
    abiCoder.encode(
      ['tuple(bytes32 salt, uint64 deadline, address portal, uint256 nativeAmount, tuple(address token, uint256 amount)[] tokens, tuple(address target, bytes data, uint256 value)[] calls)'],
      [route],
    ),
  )

  // Reward: USDT on Tron
  const reward = [BigInt(deadline), creatorHex, tronProverHex, 0, [{ token: tronUsdtHex, amount: REWARD_AMOUNT }]]
  const iface = new ethers.Interface(TRON_WITHDRAW_ABI)
  const calldata = iface.encodeFunctionData('batchWithdraw', [[evmChainId], [routeHash], [reward]])

  console.log(`  sending...`)
  const { txid, info } = await tronSendAndWait(tw, tronPortalB58, TRON_WITHDRAW_SIG, calldata.slice(10))
  metrics.tronTxs.push(tronTxMetrics('batchWithdraw', info))
  metrics.durationMs = Date.now() - t0
  console.log(`  done.`)
  return { txId: txid, metrics }
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  let pk = process.env.PRIVATE_KEY || ''
  if (pk.startsWith('0x')) pk = pk.slice(2)
  if (!pk) throw new Error('PRIVATE_KEY required')

  const rpcUrl = process.env.EVM_RPC_URL || ''
  if (!rpcUrl) throw new Error('EVM_RPC_URL required')

  const tronRpc       = process.env.TRON_RPC_URL         || 'https://api.trongrid.io'
  const tronPortalHex = process.env.TRON_PORTAL_HEX20    || '0xbbe65c636a745ccb12fb0a8376f5ed089a86983a'
  const tronProverHex = process.env.TRON_LZ_PROVER_HEX20 || '0xf8b5348d6e1e4c47de4abc2d9946963a7a37f2c8'
  const evmPortal     = process.env.EVM_PORTAL            || '0x399Dbd5DF04f83103F77A58cBa2B7c4d3cdede97'
  const evmProver     = process.env.EVM_LZ_PROVER         || '0xf64eaca0D1cF874ea34b8E73127f0Fe535c6be41'
  const pollInterval  = parseInt(process.env.POLL_INTERVAL_SEC || '30')
  const pollTimeout   = parseInt(process.env.POLL_TIMEOUT_MIN  || '60')

  const provider   = new ethers.JsonRpcProvider(rpcUrl)
  const wallet     = new ethers.Wallet('0x' + pk, provider)
  const tronGridKey = process.env.TRONGRID_API_KEY || process.env.TRONGRID_API_TOKEN || ''
  const tw         = new TronWeb({
    fullHost: tronRpc,
    privateKey: pk,
    ...(tronGridKey ? { headers: { 'TRON-PRO-API-KEY': tronGridKey } } : {}),
  })
  // Compute base58 from hex20 via TronWeb — avoids validator failures from env-var strings
  const tronPortalB58 = tw.address.fromHex('41' + tronPortalHex.slice(2)) as string

  // Detect chain IDs from the connected endpoints
  const network     = await provider.getNetwork()
  const evmChainId  = Number(network.chainId)
  const tronChainId = tronChainIdFromRpcUrl(tronRpc)

  // Resolve LZ EIDs from lzDeployments.json
  const tronEid = BigInt(eidFromNativeChainId(tronChainId))

  // Resolve token addresses from the hardcoded maps
  const evmUsdcAddr = EVM_USDC_BY_CHAIN[evmChainId]
  if (!evmUsdcAddr) throw new Error(`No USDC address configured for EVM chain ID ${evmChainId}`)
  const tronUsdtHex = TRON_USDT_HEX_BY_CHAIN[tronChainId]
  if (!tronUsdtHex) throw new Error(`No USDT address configured for Tron chain ID ${tronChainId}`)

  const chainName = EVM_CHAIN_NAMES[evmChainId] ?? `chain-${evmChainId}`
  const explorer  = getEvmExplorer(network.chainId)

  console.log(`\n${'═'.repeat(60)}`)
  console.log(`  Tron → EVM  |  Tron → ${chainName}`)
  console.log(`  Reward: 0.1 USDT on Tron | Want: 0.05 USDC on ${chainName}`)
  console.log(`${'═'.repeat(60)}`)

  const totalStart = Date.now()

  const { intentHash, salt, deadline, creatorHex, txId: createTxId, metrics: m1 } = await createIntent(
    tw, tronPortalB58, tronPortalHex, tronProverHex,
    tronUsdtHex, evmPortal, evmUsdcAddr, evmChainId, chainName,
  )

  const { txHash: fulfillTxHash, lzFeeEth, metrics: m2 } = await fulfillAndProveOnEvm(
    wallet, evmPortal, evmProver, evmUsdcAddr,
    tronPortalHex, tronProverHex, tronUsdtHex,
    tronEid, intentHash, salt, deadline, creatorHex,
  )

  const m3 = await pollForProof(tw, tronProverHex, intentHash, pollInterval, pollTimeout)

  const { txId: withdrawTxId, metrics: m4 } = await withdrawOnTron(
    tw, tronPortalB58, tronProverHex, tronUsdtHex,
    evmPortal, evmUsdcAddr, evmChainId, salt, deadline, creatorHex,
  )

  const totalMs = Date.now() - totalStart

  console.log(`\n${'═'.repeat(60)}`)
  console.log(`  SUMMARY`)
  console.log(`${'═'.repeat(60)}`)
  console.log(`  Route:       Tron → ${chainName}`)
  console.log(`  Reward:      0.1 USDT on Tron → solver`)
  console.log(`  Transferred: 0.05 USDC on ${chainName} → creator (${creatorHex})`)
  console.log(`  Intent hash: ${intentHash}`)
  console.log(``)
  console.log(`  Create:      ${TRON_EXPLORER}/${createTxId}`)
  console.log(`  Fulfill:     ${explorer}/tx/${fulfillTxHash}`)
  console.log(`  Withdraw:    ${TRON_EXPLORER}/${withdrawTxId}`)

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

  for (const m of [m1, m2, m3, m4]) {
    console.log(`  ${m.name}  (${fmtMs(m.durationMs)})`)
    for (const t of m.evmTxs) {
      const usd = parseFloat(t.costEth) * ETH_USD
      totalUsd += usd
      console.log(`    [EVM] ${t.label}`)
      console.log(`          gas: ${t.gasUsed.toLocaleString()}  price: ${ethers.formatUnits(t.gasPrice, 'gwei')} gwei  cost: ${t.costEth} ETH  ≈ $${usd.toFixed(4)}`)
    }
    for (const t of m.tronTxs) {
      const energyFeetrx = (t.energyFee / 1_000_000).toFixed(6)
      const netFeetrx    = (t.netFee    / 1_000_000).toFixed(6)
      const bwFeeSun     = t.netFee - t.energyFee
      const bwFeeTrx     = (bwFeeSun / 1_000_000).toFixed(6)
      const bwAmount     = Math.round(bwFeeSun / 1_000)
      const rentalTrx    = t.energyUsed * ENERGY_RENTAL
      const usd          = (rentalTrx + bwFeeSun / 1_000_000) * TRX_USD
      totalUsd += usd
      console.log(`    [TRX] ${t.label}`)
      console.log(`          energy: ${t.energyUsed.toLocaleString()}  energyFee: ${energyFeetrx} TRX  rental: ${rentalTrx.toFixed(4)} TRX`)
      console.log(`          bandwidth: ${bwAmount} units  bandwidthFee: ${bwFeeTrx} TRX  totalFee: ${netFeetrx} TRX  ≈ $${usd.toFixed(4)}`)
    }
  }
  const lzFeeUsd = parseFloat(lzFeeEth) * ETH_USD
  totalUsd += lzFeeUsd

  console.log(``)
  console.log(`  LZ bridge fee:         ${lzFeeEth} ETH  ≈ $${lzFeeUsd.toFixed(4)}`)
  console.log(`  Total cost (rental):   $${totalUsd.toFixed(4)}`)
  console.log(`${'═'.repeat(60)}`)

  // ─── Cost range analysis ──────────────────────────────────────────────────────
  // No variable slots: approve=existing, vault=always new, solver receive=always existing
  // Only the USDT energy factor varies (0 = best, 3.4 = worst/current max)
  const tronTxsAll     = [...m1.tronTxs, ...m4.tronTxs]
  const detectedFactor = tronTxsAll[0].energyUsed / USDT_BASE_EXISTING - 1  // from approve
  const totalObsEnergy = tronTxsAll.reduce((s, t) => s + t.energyUsed, 0)
  const totalObsBwSun  = tronTxsAll.reduce((s, t) => s + (t.netFee - t.energyFee), 0)

  const fixedNonUsdt = totalObsEnergy - Math.round(TRON_EVM_USDT_BASE * (1 + detectedFactor))

  const calcCost = (f: number): number => {
    const energy = fixedNonUsdt + Math.round(TRON_EVM_USDT_BASE * (1 + f))
    return (energy * ENERGY_RENTAL + totalObsBwSun / 1_000_000) * TRX_USD + lzFeeUsd
  }

  console.log(`\n${'═'.repeat(60)}`)
  console.log(`  COST RANGE`)
  console.log(`  This run: factor ${detectedFactor.toFixed(2)} (max 3.4) · all slots fixed`)
  console.log(`  Assumptions: rental 3.7 TRX/100k · LZ fee constant · vault always new`)
  console.log(`    · approval always existing · solver receive always existing`)
  console.log(`    · bandwidth 1 TRX/1,000 · TRX $${TRX_USD} · ETH $${ETH_USD}`)
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
