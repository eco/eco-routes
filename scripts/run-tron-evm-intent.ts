/**
 * run-tron-evm-intent.ts
 *
 * Full lifecycle for a Tron → EVM intent:
 *   1. Approve + PublishAndFund intent on Tron (source): reward = 0.1 USDT locked on Tron
 *   2. Approve USDC + FulfillAndProve on EVM (destination): sends 0.1 USDC to creator, LZ proof → Tron
 *   3. Poll Tron prover until proof arrives
 *   4. Withdraw USDT reward on Tron
 *
 * Required env vars:
 *   PRIVATE_KEY   - hex private key (with or without 0x)
 *   EVM_RPC_URL   - RPC endpoint for the destination EVM chain
 *   EVM_CHAIN_ID  - chain ID of the destination EVM chain (e.g. 10=Optimism, 8453=Base)
 *
 * Optional env vars (defaults to standard deployed addresses):
 *   TRON_RPC_URL          (default: https://api.trongrid.io)
 *   TRON_PORTAL_BASE58    (default: TCwhEAaWQhN9sCSn2RshG5bb1aciukpWjr)
 *   TRON_PORTAL_HEX20     (default: 0x209f1b776a365c95fddf00876b3dbe300fd08de2)
 *   TRON_LZ_PROVER_HEX20  (default: 0xfc462a59bc1df059914624a0e86e220f84426325)
 *   EVM_PORTAL            (default: 0x399Dbd5DF04f83103F77A58cBa2B7c4d3cdede97)
 *   EVM_LZ_PROVER         (default: 0xA23ab6E17d0168FACc16a614579198FD58E7bC41)
 *   TRON_EID              (default: 30420)
 *   TRON_USDT_HEX20       (default: 0xa614f803b6fd780986a42c78ec9c7f77e6ded13 — Tron mainnet USDT)
 *   EVM_USDC              (default: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 — Base USDC)
 *   EVM_CHAIN_NAME        (default: EVM) — used for display only
 *   POLL_INTERVAL_SEC     (default: 30)  — seconds between proof polls
 *   POLL_TIMEOUT_MIN      (default: 60)  — minutes before giving up
 *
 * Usage:
 *   set -a && source .env.tron && set +a
 *   EVM_RPC_URL=https://mainnet.base.org EVM_CHAIN_ID=8453 EVM_CHAIN_NAME=Base \
 *     npx ts-node scripts/run-tron-evm-intent.ts
 */

import { TronWeb } from 'tronweb'
import { ethers } from 'ethers'
import 'dotenv/config'

// ─── Constants ────────────────────────────────────────────────────────────────

const TRON_EXPLORER  = 'https://tronscan.org/#/transaction'
const REWARD_AMOUNT  = 100_000n  // 0.1 USDT / USDC (6 decimals)

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
    type: 'function', name: 'withdraw',
    inputs: [
      { name: 'destination', type: 'uint64' },
      { name: 'routeHash', type: 'bytes32' },
      { name: 'reward', type: 'tuple', components: [
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
  'withdraw(uint64,bytes32,(uint64,address,address,uint256,(address,uint256)[]))'

const TRON_ERC20_APPROVE_SIG = 'approve(address,uint256)'

// ─── Helpers ──────────────────────────────────────────────────────────────────

const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))

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
): Promise<{ intentHash: string; salt: string; deadline: number; creatorHex: string; txId: string }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 1 — Approve USDT + PublishAndFund intent on Tron → ${chainName}`)
  console.log(`${'─'.repeat(60)}`)

  const deployerTronAddr = tw.address.fromPrivateKey(tw.defaultPrivateKey as string) as string
  const creatorHex = '0x' + (tw.address.toHex(deployerTronAddr) as string).slice(2)

  const deadline = Math.floor(Date.now() / 1000) + 24 * 60 * 60
  const salt = ethers.keccak256(ethers.toUtf8Bytes(`eco-routes-tron-${chainName}-${Date.now()}`))

  // Encode EVM-side route.calls: Executor (who receives route.tokens) transfers USDC to creator
  const transferData = ERC20_TRANSFER_IFACE.encodeFunctionData('transfer', [creatorHex, REWARD_AMOUNT])

  const intent = [
    evmChainId,
    // route: what solver must do on EVM — provide 0.1 USDC, Executor transfers it to creator
    [
      salt, deadline, evmPortalHex, 0,
      [{ token: evmUsdcAddr, amount: REWARD_AMOUNT }],          // route.tokens: solver pre-approves USDC to EVM portal
      [{ target: evmUsdcAddr, data: transferData, value: 0 }],  // route.calls: Executor sends USDC to creator
    ],
    // reward: 0.1 USDT locked on Tron for the solver
    [deadline, creatorHex, tronProverHex, 0, [{ token: tronUsdtHex, amount: REWARD_AMOUNT }]],
  ]

  console.log(`  Creator:   ${deployerTronAddr} (${creatorHex})`)
  console.log(`  Deadline:  ${new Date(deadline * 1000).toISOString()}`)
  console.log(`  Reward:    0.1 USDT (${tronUsdtHex}) locked on Tron`)
  console.log(`  Want:      0.1 USDC (${evmUsdcAddr}) sent to creator on ${chainName}`)

  // 1a. Approve Tron USDT to portal (needed for publishAndFund to pull tokens into vault)
  console.log(`  Approving 0.1 USDT to Tron portal...`)
  const tronUsdtB58 = tw.address.fromHex('41' + tronUsdtHex.slice(2)) as string
  const approveCalldata = ERC20_IFACE.encodeFunctionData('approve', [tronPortalHex, REWARD_AMOUNT])
  await tronSendAndWait(tw, tronUsdtB58, TRON_ERC20_APPROVE_SIG, approveCalldata.slice(10))
  console.log(`  Approved.`)

  // 1b. PublishAndFund
  console.log(`  Sending publishAndFund...`)
  const iface = new ethers.Interface(TRON_PUBLISH_AND_FUND_ABI)
  const calldata = iface.encodeFunctionData('publishAndFund', [intent, false])

  const { txid, info } = await tronSendAndWait(tw, tronPortalB58, TRON_PUBLISH_AND_FUND_SIG, calldata.slice(10))

  const topic = ethers.id('IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])')
  let intentHash = ''
  for (const log of info.log || []) {
    if (log.topics?.[0] === topic.slice(2)) { intentHash = '0x' + log.topics[1]; break }
  }
  if (!intentHash) throw new Error('IntentPublished event not found')

  console.log(`  done. Intent hash: ${intentHash}`)
  return { intentHash, salt, deadline, creatorHex, txId: txid }
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
): Promise<{ txHash: string }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 2 — Approve USDC + FulfillAndProve on EVM`)
  console.log(`${'─'.repeat(60)}`)

  const abiCoder = ethers.AbiCoder.defaultAbiCoder()
  const provider = wallet.provider!

  // Encode the same transfer call that was put in route.calls at publish time
  const transferData = ERC20_TRANSFER_IFACE.encodeFunctionData('transfer', [creatorHex, REWARD_AMOUNT])

  const route = {
    salt,
    deadline: BigInt(deadline),
    portal: evmPortal,
    nativeAmount: 0n,
    tokens: [{ token: evmUsdcAddr, amount: REWARD_AMOUNT }],
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
  console.log(`  Approving 0.1 USDC to EVM portal...`)
  const usdc = new ethers.Contract(evmUsdcAddr, ERC20_ABI, wallet)
  const approveTx = await usdc.approve(evmPortal, REWARD_AMOUNT)
  await approveTx.wait()
  console.log(`  Approved.`)

  console.log(`  sending fulfillAndProve...`)
  const portal = new ethers.Contract(evmPortal, EVM_FULFILL_AND_PROVE_ABI, wallet)
  const tx = await portal.fulfillAndProve(
    intentHash, route, rewardHash, claimant,
    evmProver, tronEid, lzData,
    { value: fee + fee / 10n },
  )
  await tx.wait()
  console.log(`  done.`)
  return { txHash: tx.hash }
}

// ─── Step 3: Poll Tron prover for proof ───────────────────────────────────────

async function pollForProof(
  tw: TronWeb,
  tronProverHex: string,
  intentHash: string,
  intervalSec: number,
  timeoutMin: number,
): Promise<void> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 3 — Polling Tron prover for proof (timeout: ${timeoutMin}m)`)
  console.log(`${'─'.repeat(60)}`)

  const tronProverB58 = tw.address.fromHex('41' + tronProverHex.slice(2)) as string
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()
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
      return
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
): Promise<{ txId: string }> {
  console.log(`\n${'─'.repeat(60)}`)
  console.log(`STEP 4 — Withdraw USDT on Tron`)
  console.log(`${'─'.repeat(60)}`)

  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  // Reconstruct the exact same route that was published
  const transferData = ERC20_TRANSFER_IFACE.encodeFunctionData('transfer', [creatorHex, REWARD_AMOUNT])
  const route = {
    salt,
    deadline: BigInt(deadline),
    portal: evmPortalHex,
    nativeAmount: 0n,
    tokens: [{ token: evmUsdcAddr, amount: REWARD_AMOUNT }] as any[],
    calls:  [{ target: evmUsdcAddr, data: transferData, value: 0n }] as any[],
  }
  const routeHash = ethers.keccak256(
    abiCoder.encode(
      ['tuple(bytes32 salt, uint64 deadline, address portal, uint256 nativeAmount, tuple(address token, uint256 amount)[] tokens, tuple(address target, bytes data, uint256 value)[] calls)'],
      [route],
    ),
  )

  // Reward includes the USDT token
  const reward = [BigInt(deadline), creatorHex, tronProverHex, 0, [{ token: tronUsdtHex, amount: REWARD_AMOUNT }]]
  const iface = new ethers.Interface(TRON_WITHDRAW_ABI)
  const calldata = iface.encodeFunctionData('withdraw', [evmChainId, routeHash, reward])

  console.log(`  sending...`)
  const { txid } = await tronSendAndWait(tw, tronPortalB58, TRON_WITHDRAW_SIG, calldata.slice(10))
  console.log(`  done.`)
  return { txId: txid }
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  let pk = process.env.PRIVATE_KEY || ''
  if (pk.startsWith('0x')) pk = pk.slice(2)
  if (!pk) throw new Error('PRIVATE_KEY required')

  const rpcUrl        = process.env.EVM_RPC_URL || '';   if (!rpcUrl) throw new Error('EVM_RPC_URL required')
  const evmChainIdStr = process.env.EVM_CHAIN_ID || '';  if (!evmChainIdStr) throw new Error('EVM_CHAIN_ID required')

  const tronRpc       = process.env.TRON_RPC_URL         || 'https://api.trongrid.io'
  const tronPortalHex = process.env.TRON_PORTAL_HEX20    || '0x209f1b776a365c95fddf00876b3dbe300fd08de2'
  const tronProverHex = process.env.TRON_LZ_PROVER_HEX20 || '0xfc462a59bc1df059914624a0e86e220f84426325'
  const evmPortal     = process.env.EVM_PORTAL            || '0x399Dbd5DF04f83103F77A58cBa2B7c4d3cdede97'
  const evmProver     = process.env.EVM_LZ_PROVER         || '0xA23ab6E17d0168FACc16a614579198FD58E7bC41'
  const tronEid       = BigInt(process.env.TRON_EID       || '30420')
  const tronUsdtHex   = process.env.TRON_USDT_HEX20      || '0xa614f803b6fd780986a42c78ec9c7f77e6ded13c'
  const evmUsdcAddr   = process.env.EVM_USDC              || '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913'
  const chainName     = process.env.EVM_CHAIN_NAME        || 'EVM'
  const pollInterval  = parseInt(process.env.POLL_INTERVAL_SEC || '30')
  const pollTimeout   = parseInt(process.env.POLL_TIMEOUT_MIN  || '60')

  const evmChainId = Number(evmChainIdStr)
  const provider   = new ethers.JsonRpcProvider(rpcUrl)
  const wallet     = new ethers.Wallet('0x' + pk, provider)
  const tw         = new TronWeb({ fullHost: tronRpc, privateKey: pk })
  // Compute base58 from hex20 via TronWeb — avoids validator failures from env-var strings
  const tronPortalB58 = tw.address.fromHex('41' + tronPortalHex.slice(2)) as string
  const network    = await provider.getNetwork()
  const explorer   = getEvmExplorer(network.chainId)

  console.log(`\n${'═'.repeat(60)}`)
  console.log(`  Tron → EVM  |  Tron → ${chainName}`)
  console.log(`  Reward: 0.1 USDT on Tron | Want: 0.1 USDC on ${chainName}`)
  console.log(`${'═'.repeat(60)}`)

  const { intentHash, salt, deadline, creatorHex, txId: createTxId } = await createIntent(
    tw, tronPortalB58, tronPortalHex, tronProverHex,
    tronUsdtHex, evmPortal, evmUsdcAddr, evmChainId, chainName,
  )

  const { txHash: fulfillTxHash } = await fulfillAndProveOnEvm(
    wallet, evmPortal, evmProver, evmUsdcAddr,
    tronPortalHex, tronProverHex, tronUsdtHex,
    tronEid, intentHash, salt, deadline, creatorHex,
  )

  await pollForProof(tw, tronProverHex, intentHash, pollInterval, pollTimeout)

  const { txId: withdrawTxId } = await withdrawOnTron(
    tw, tronPortalB58, tronProverHex, tronUsdtHex,
    evmPortal, evmUsdcAddr, evmChainId, salt, deadline, creatorHex,
  )

  console.log(`\n${'═'.repeat(60)}`)
  console.log(`  SUMMARY`)
  console.log(`${'═'.repeat(60)}`)
  console.log(`  Route:       Tron → ${chainName}`)
  console.log(`  Reward:      0.1 USDT on Tron → solver`)
  console.log(`  Transferred: 0.1 USDC on ${chainName} → creator (${creatorHex})`)
  console.log(`  Intent hash: ${intentHash}`)
  console.log(``)
  console.log(`  Create:      ${TRON_EXPLORER}/${createTxId}`)
  console.log(`  Fulfill:     ${explorer}/tx/${fulfillTxHash}`)
  console.log(`  Withdraw:    ${TRON_EXPLORER}/${withdrawTxId}`)
  console.log(`${'═'.repeat(60)}\n`)
}

main().catch((err) => { console.error(err); process.exit(1) })
