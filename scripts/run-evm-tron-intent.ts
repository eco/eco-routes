/**
 * run-evm-tron-intent.ts
 *
 * Full lifecycle for an EVM → Tron intent:
 *   1. Approve USDC + PublishAndFund intent on EVM (source): reward = 0.1 USDC locked on EVM
 *   2. Approve USDT + FulfillAndProve on Tron (destination): sends 0.05 USDT to creator, LZ proof → EVM
 *   3. Poll EVM prover until proof arrives
 *   4. Withdraw USDC reward on EVM
 *
 * Required env vars:
 *   PRIVATE_KEY   - hex private key (with or without 0x)
 *   EVM_RPC_URL   - RPC endpoint for the source EVM chain
 *   EVM_EID       - LayerZero EID of the source EVM chain (e.g. 30184=Base, 30111=Optimism)
 *
 * Optional env vars (defaults to standard deployed addresses):
 *   EVM_PORTAL            (default: 0x399Dbd5DF04f83103F77A58cBa2B7c4d3cdede97)
 *   EVM_LZ_PROVER         (default: 0xf64eaca0D1cF874ea34b8E73127f0Fe535c6be41)
 *   TRON_RPC_URL          (default: https://api.trongrid.io)
 *   TRON_PORTAL_BASE58    (default: TT6jKgnBXoj7vZ7m2Yioq5mxTfrDpgir44)
 *   TRON_PORTAL_HEX20     (default: 0xbbe65c636a745ccb12fb0a8376f5ed089a86983a)
 *   TRON_LZ_PROVER_HEX20  (default: 0xf8b5348d6e1e4c47de4abc2d9946963a7a37f2c8)
 *   EVM_USDC              (default: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 — Base USDC)
 *   TRON_USDT_HEX20       (default: 0xa614f803b6fd780986a42c78ec9c7f77e6ded13 — Tron mainnet USDT)
 *   EVM_CHAIN_NAME        (default: EVM) — used for display only
 *   POLL_INTERVAL_SEC     (default: 30)  — seconds between proof polls
 *   POLL_TIMEOUT_MIN      (default: 60)  — minutes before giving up
 *
 * Usage:
 *   set -a && source .env.tron && set +a
 *   EVM_RPC_URL=https://mainnet.base.org EVM_EID=30184 EVM_CHAIN_NAME=Base \
 *     npx ts-node scripts/run-evm-tron-intent.ts
 */

import { ethers } from 'ethers'
import { TronWeb } from 'tronweb'
import 'dotenv/config'

// ─── Constants ────────────────────────────────────────────────────────────────

// TRON_CHAIN_ID is read from env in main() — mainnet: 728126428, Shasta testnet: 2494104990
let TRON_CHAIN_ID = 728126428
const TRON_EXPLORER  = 'https://tronscan.org/#/transaction'
const REWARD_AMOUNT  = 100_000n  // 0.1 USDC (6 decimals) — locked on EVM as reward
const ROUTE_AMOUNT   =  50_000n  // 0.05 USDT (6 decimals) — solver provides on Tron

// ─── ABIs ─────────────────────────────────────────────────────────────────────

const PUBLISH_AND_FUND_ABI = [
  `function publishAndFund(
    tuple(
      uint64 destination,
      tuple(bytes32 salt, uint64 deadline, address portal, uint256 nativeAmount,
            tuple(address token, uint256 amount)[] tokens,
            tuple(address target, bytes data, uint256 value)[] calls) route,
      tuple(uint64 deadline, address creator, address prover, uint256 nativeAmount,
            tuple(address token, uint256 amount)[] tokens) reward
    ) intent,
    bool allowPartial
  ) external payable returns (bytes32 intentHash, address vault)`,
]

const WITHDRAW_ABI = [
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

const FULFILL_AND_PROVE_SIG =
  'fulfillAndProve(bytes32,(bytes32,uint64,address,uint256,(address,uint256)[],(address,bytes,uint256)[]),bytes32,bytes32,address,uint64,bytes)'

const TRON_IFACE = new ethers.Interface([
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
])

const PROVEN_INTENTS_ABI = ['function provenIntents(bytes32) external view returns (address)']

const ERC20_ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
]

const ERC20_IFACE          = new ethers.Interface(ERC20_ABI)
const ERC20_TRANSFER_IFACE = new ethers.Interface(['function transfer(address to, uint256 amount) returns (bool)'])
const TRON_ERC20_APPROVE_SIG = 'approve(address,uint256)'

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
  const lzOptions =
    '0x' + '0003' + '01' + '0011' + '01' +
    gasLimit.toString(16).padStart(32, '0')
  return abiCoder.encode(
    ['tuple(bytes32 sourceChainProver, bytes options, uint256 gasLimit)'],
    [{ sourceChainProver, options: lzOptions, gasLimit }],
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
  for (let i = 0; i < 20; i++) {
    await sleep(3000)
    const info: any = await tw.trx.getTransactionInfo(broadcast.txid)
    if (info?.id) {
      if (info.receipt?.result !== 'SUCCESS') throw new Error(`Tx failed: ${JSON.stringify(info)}`)
      return { txid: broadcast.txid, info }
    }
  }
  throw new Error(`Timed out waiting for ${broadcast.txid}`)
}

// ─── Step 1: Approve USDC + PublishAndFund intent on EVM ──────────────────────

async function createIntent(
  wallet: ethers.Wallet,
  evmPortal: string,
  evmProver: string,
  evmUsdcAddr: string,
  tronPortalHex: string,
  tronUsdtHex: string,
  chainName: string,
): Promise<{ intentHash: string; salt: string; deadline: number; txHash: string }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 1 — Approve USDC + PublishAndFund intent on ${chainName}`)
  console.log(`${'─'.repeat(60)}`)

  const deadline = Math.floor(Date.now() / 1000) + 24 * 60 * 60
  const salt = ethers.keccak256(ethers.toUtf8Bytes(`eco-routes-${chainName}-tron-${Date.now()}`))
  const creatorHex = wallet.address.toLowerCase()

  // Encode Tron-side route.calls: Executor (who receives route.tokens) transfers USDT to creator
  // The creator's address is the same 20-byte key on both EVM and Tron
  const transferData = ERC20_TRANSFER_IFACE.encodeFunctionData('transfer', [creatorHex, ROUTE_AMOUNT])

  const intent = {
    destination: TRON_CHAIN_ID,
    // route: what solver must do on Tron — provide 0.05 USDT, Executor transfers it to creator
    route: {
      salt,
      deadline,
      portal: tronPortalHex,
      nativeAmount: 0n,
      tokens: [{ token: tronUsdtHex, amount: ROUTE_AMOUNT }],          // solver pre-approves USDT to Tron portal
      calls:  [{ target: tronUsdtHex, data: transferData, value: 0n }], // Executor sends USDT to creator
    },
    // reward: 0.1 USDC locked on EVM for the solver
    reward: {
      deadline,
      creator: wallet.address,
      prover: evmProver,
      nativeAmount: 0n,
      tokens: [{ token: evmUsdcAddr, amount: REWARD_AMOUNT }],
    },
  }

  console.log(`  Wallet:    ${wallet.address}`)
  console.log(`  Deadline:  ${new Date(deadline * 1000).toISOString()}`)
  console.log(`  Reward:    0.1 USDC (${evmUsdcAddr}) locked on ${chainName}`)
  console.log(`  Want:      0.05 USDT (${tronUsdtHex}) sent to creator on Tron`)

  // 1a. Approve USDC to EVM portal (needed for publishAndFund to pull tokens into vault)
  console.log(`  Approving 0.1 USDC to EVM portal...`)  // reward amount
  const usdc = new ethers.Contract(evmUsdcAddr, ERC20_ABI, wallet)
  const approveTx = await usdc.approve(evmPortal, REWARD_AMOUNT)
  await approveTx.wait()
  console.log(`  Approved.`)

  // 1b. PublishAndFund
  console.log(`  Sending publishAndFund...`)
  const portal = new ethers.Contract(evmPortal, PUBLISH_AND_FUND_ABI, wallet)
  const tx = await portal.publishAndFund(intent, false)
  const receipt = await tx.wait()

  const topic = ethers.id('IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])')
  let intentHash = ''
  for (const log of receipt.logs) {
    if (log.topics[0] === topic) { intentHash = log.topics[1]; break }
  }
  if (!intentHash) throw new Error('IntentPublished event not found')

  console.log(`  done. Intent hash: ${intentHash}`)
  return { intentHash, salt, deadline, txHash: tx.hash }
}

// ─── Step 2: Approve USDT + FulfillAndProve on Tron ───────────────────────────

async function fulfillAndProveOnTron(
  tw: TronWeb,
  tronPortalB58: string,
  tronPortalHex: string,
  tronProverHex: string,
  tronUsdtHex: string,
  evmProver: string,
  evmUsdcAddr: string,
  evmEid: bigint,
  intentHash: string,
  salt: string,
  deadline: number,
  creatorHex: string,
): Promise<{ txId: string }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 2 — Approve USDT + FulfillAndProve on Tron`)
  console.log(`${'─'.repeat(60)}`)

  const tronProverB58 = tw.address.fromHex('41' + tronProverHex.slice(2)) as string
  const tronUsdtB58   = tw.address.fromHex('41' + tronUsdtHex.slice(2)) as string
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  const deployerTronAddr = tw.address.fromPrivateKey(tw.defaultPrivateKey as string) as string
  const deployerHex20 = '0x' + (tw.address.toHex(deployerTronAddr) as string).slice(2)

  // Encode the same transfer call that was put in route.calls at publish time
  const transferData = ERC20_TRANSFER_IFACE.encodeFunctionData('transfer', [creatorHex, ROUTE_AMOUNT])

  const route = {
    salt,
    deadline: BigInt(deadline),
    portal: tronPortalHex,
    nativeAmount: 0n,
    tokens: [{ token: tronUsdtHex, amount: ROUTE_AMOUNT }] as any[],
    calls:  [{ target: tronUsdtHex, data: transferData, value: 0n }] as any[],
  }
  const reward = {
    deadline: BigInt(deadline),
    creator: creatorHex,
    prover: evmProver,
    nativeAmount: 0n,
    tokens: [{ token: evmUsdcAddr, amount: REWARD_AMOUNT }] as any[],
  }

  const rewardHash = ethers.keccak256(
    abiCoder.encode(
      ['tuple(uint64 deadline, address creator, address prover, uint256 nativeAmount, tuple(address token, uint256 amount)[] tokens)'],
      [reward],
    ),
  )
  const claimant = ethers.zeroPadValue(deployerHex20, 32)
  const encodedProofs = ethers.concat([intentHash, claimant])
  const lzData = buildLzData(abiCoder, evmProver)

  // Fetch LZ fee
  const feeCalldata = TRON_IFACE.encodeFunctionData('fetchFee', [evmEid, encodedProofs, lzData])
  const feeResult: any = await tw.transactionBuilder.triggerConstantContract(
    tronProverB58, 'fetchFee(uint64,bytes,bytes)',
    { rawParameter: feeCalldata.slice(10) }, [],
    tw.defaultAddress.hex as string,
  )
  const feeHex = feeResult?.constant_result?.[0]
  if (!feeHex) throw new Error('fetchFee returned no result')
  const fee = abiCoder.decode(['uint256'], '0x' + feeHex)[0] as bigint
  console.log(`  LZ fee: ${ethers.formatUnits(fee, 6)} TRX`)

  // 2a. Approve Tron USDT to portal (solver must pre-approve so portal can pull into Executor)
  console.log(`  Approving 0.05 USDT to Tron portal...`)
  const approveCalldata = ERC20_IFACE.encodeFunctionData('approve', [tronPortalHex, ROUTE_AMOUNT])
  await tronSendAndWait(tw, tronUsdtB58, TRON_ERC20_APPROVE_SIG, approveCalldata.slice(10))
  console.log(`  Approved.`)

  // 2b. FulfillAndProve
  const calldata = TRON_IFACE.encodeFunctionData('fulfillAndProve', [
    intentHash, route, rewardHash, claimant, tronProverHex, evmEid, lzData,
  ])

  console.log(`  sending fulfillAndProve...`)
  const result = await tw.transactionBuilder.triggerSmartContract(
    tronPortalB58, FULFILL_AND_PROVE_SIG,
    { feeLimit: 500_000_000, callValue: Number(fee + fee / 10n), rawParameter: calldata.slice(10) },
    [],
  )
  if (!result.result?.result) throw new Error(`triggerSmartContract failed: ${JSON.stringify(result)}`)

  const signed = await tw.trx.sign(result.transaction)
  const broadcast = await tw.trx.sendRawTransaction(signed)
  if (!broadcast.result) throw new Error(`Broadcast failed: ${JSON.stringify(broadcast)}`)

  for (let i = 0; i < 20; i++) {
    await sleep(3000)
    const info: any = await tw.trx.getTransactionInfo(broadcast.txid)
    if (info?.id) {
      if (info.receipt?.result !== 'SUCCESS') throw new Error(`Tx failed: ${JSON.stringify(info)}`)
      console.log(`  done.`)
      return { txId: broadcast.txid }
    }
  }
  throw new Error(`Timed out waiting for fulfillAndProve`)
}

// ─── Step 3: Poll EVM prover for proof ────────────────────────────────────────

async function pollForProof(
  provider: ethers.JsonRpcProvider,
  evmProver: string,
  intentHash: string,
  intervalSec: number,
  timeoutMin: number,
): Promise<void> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 3 — Polling EVM prover for proof (timeout: ${timeoutMin}m)`)
  console.log(`${'─'.repeat(60)}`)

  const prover = new ethers.Contract(evmProver, PROVEN_INTENTS_ABI, provider)
  const polls  = Math.ceil((timeoutMin * 60) / intervalSec)

  for (let i = 1; i <= polls; i++) {
    const claimant: string = await prover.provenIntents(intentHash)
    if (claimant !== ethers.ZeroAddress) {
      console.log(`  Proof arrived!`)
      return
    }
    console.log(`  [${i}/${polls}] waiting ${intervalSec}s...`)
    await sleep(intervalSec * 1000)
  }
  throw new Error(`Proof did not arrive within ${timeoutMin} minutes`)
}

// ─── Step 4: Withdraw USDC on EVM ─────────────────────────────────────────────

async function withdrawOnEvm(
  wallet: ethers.Wallet,
  evmPortal: string,
  evmProver: string,
  evmUsdcAddr: string,
  tronPortalHex: string,
  tronUsdtHex: string,
  intentSalt: string,
  deadline: number,
  creatorHex: string,
): Promise<{ txHash: string }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 4 — Withdraw USDC reward on EVM`)
  console.log(`${'─'.repeat(60)}`)

  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  // Reconstruct the exact same route that was published
  const transferData = ERC20_TRANSFER_IFACE.encodeFunctionData('transfer', [creatorHex, ROUTE_AMOUNT])
  const route = {
    salt: intentSalt,
    deadline: BigInt(deadline),
    portal: tronPortalHex,
    nativeAmount: 0n,
    tokens: [{ token: tronUsdtHex, amount: ROUTE_AMOUNT }] as any[],
    calls:  [{ target: tronUsdtHex, data: transferData, value: 0n }] as any[],
  }
  const routeHash = ethers.keccak256(
    abiCoder.encode(
      ['tuple(bytes32 salt, uint64 deadline, address portal, uint256 nativeAmount, tuple(address token, uint256 amount)[] tokens, tuple(address target, bytes data, uint256 value)[] calls)'],
      [route],
    ),
  )

  // Reward includes the USDC token
  const reward = [BigInt(deadline), creatorHex, evmProver, 0n, [{ token: evmUsdcAddr, amount: REWARD_AMOUNT }]]

  console.log(`  sending...`)
  const portal = new ethers.Contract(evmPortal, WITHDRAW_ABI, wallet)
  const tx = await portal.batchWithdraw([TRON_CHAIN_ID], [routeHash], [reward])
  await tx.wait()
  console.log(`  done.`)
  return { txHash: tx.hash }
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  let pk = process.env.PRIVATE_KEY || ''
  if (pk.startsWith('0x')) pk = pk.slice(2)
  if (!pk) throw new Error('PRIVATE_KEY required')

  const rpcUrl    = process.env.EVM_RPC_URL || ''; if (!rpcUrl) throw new Error('EVM_RPC_URL required')
  const evmEidStr = process.env.EVM_EID || '';     if (!evmEidStr) throw new Error('EVM_EID required')

  const evmPortal     = process.env.EVM_PORTAL           || '0x399Dbd5DF04f83103F77A58cBa2B7c4d3cdede97'
  const evmProver     = process.env.EVM_LZ_PROVER        || '0xf64eaca0D1cF874ea34b8E73127f0Fe535c6be41'
  const tronRpc       = process.env.TRON_RPC_URL         || 'https://api.trongrid.io'
  const tronPortalHex = process.env.TRON_PORTAL_HEX20    || '0xbbe65c636a745ccb12fb0a8376f5ed089a86983a'
  const tronProverHex = process.env.TRON_LZ_PROVER_HEX20 || '0xf8b5348d6e1e4c47de4abc2d9946963a7a37f2c8'
  const evmUsdcAddr   = process.env.EVM_USDC             || '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'
  const tronUsdtHex   = process.env.TRON_USDT_HEX20      || '0xa614f803b6fd780986a42c78ec9c7f77e6ded13c'
  const chainName     = process.env.EVM_CHAIN_NAME       || 'EVM'
  TRON_CHAIN_ID       = parseInt(process.env.TRON_CHAIN_ID || '728126428')
  const pollInterval  = parseInt(process.env.POLL_INTERVAL_SEC || '30')
  const pollTimeout   = parseInt(process.env.POLL_TIMEOUT_MIN  || '60')

  const evmEid   = BigInt(evmEidStr)
  const provider = new ethers.JsonRpcProvider(rpcUrl)
  const wallet   = new ethers.Wallet('0x' + pk, provider)
  const tw       = new TronWeb({ fullHost: tronRpc, privateKey: pk })
  // Compute base58 from hex20 via TronWeb — avoids validator failures from env-var strings
  const tronPortalB58 = tw.address.fromHex('41' + tronPortalHex.slice(2)) as string
  const network  = await provider.getNetwork()
  const explorer = getEvmExplorer(network.chainId)

  const creatorHex = wallet.address.toLowerCase()

  console.log(`\n${'═'.repeat(60)}`)
  console.log(`  EVM → Tron  |  ${chainName} → Tron`)
  console.log(`  Reward: 0.1 USDC on ${chainName} | Want: 0.05 USDT on Tron`)
  console.log(`${'═'.repeat(60)}`)

  const { intentHash, salt, deadline, txHash: createTx } = await createIntent(
    wallet, evmPortal, evmProver, evmUsdcAddr, tronPortalHex, tronUsdtHex, chainName,
  )

  const { txId: fulfillTxId } = await fulfillAndProveOnTron(
    tw, tronPortalB58, tronPortalHex, tronProverHex, tronUsdtHex,
    evmProver, evmUsdcAddr, evmEid, intentHash, salt, deadline, creatorHex,
  )

  await pollForProof(provider, evmProver, intentHash, pollInterval, pollTimeout)

  const { txHash: withdrawTx } = await withdrawOnEvm(
    wallet, evmPortal, evmProver, evmUsdcAddr,
    tronPortalHex, tronUsdtHex, salt, deadline, creatorHex,
  )

  console.log(`\n${'═'.repeat(60)}`)
  console.log(`  SUMMARY`)
  console.log(`${'═'.repeat(60)}`)
  console.log(`  Route:       ${chainName} → Tron`)
  console.log(`  Reward:      0.1 USDC on ${chainName} → solver`)
  console.log(`  Transferred: 0.05 USDT on Tron → creator (${creatorHex})`)
  console.log(`  Intent hash: ${intentHash}`)
  console.log(``)
  console.log(`  Create:      ${explorer}/tx/${createTx}`)
  console.log(`  Fulfill:     ${TRON_EXPLORER}/${fulfillTxId}`)
  console.log(`  Withdraw:    ${explorer}/tx/${withdrawTx}`)
  console.log(`${'═'.repeat(60)}\n`)
}

main().catch((err) => { console.error(err); process.exitCode = 1 })
