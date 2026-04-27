/**
 * test-tron-vault-bug.ts
 *
 * Integration test demonstrating the CREATE2 prefix mismatch bug in
 * IntentSourceTron on Tron Shasta.
 *
 * Bug summary:
 *   - _getVault()         uses 0x41 prefix → predicted address A
 *   - new Proxy{salt:...} uses 0xff prefix → deployed address B
 *   - fund() sends tokens to A (undeployed, no code)
 *   - withdraw()/refund() deploy vault at B (empty) and operate on B
 *   - Tokens at A are permanently stuck
 *
 * Required env vars:
 *   PRIVATE_KEY              hex private key (with or without 0x)
 *   TRON_SHASTA_RPC_URL      (default: https://api.shasta.trongrid.io)
 *
 * Optional:
 *   TRON_PORTAL_CONTRACT     existing Shasta PortalTron address (skip deploy)
 *   TRON_VAULT_IMPL          existing VaultTron implementation address
 *   TRON_TEST_PROVER         existing Shasta TestProver address (skip deploy)
 *
 * Usage:
 *   npx ts-node scripts/test-tron-vault-bug.ts
 */

import { TronWeb } from 'tronweb'
import { ethers } from 'ethers'
import fs from 'fs'
import path from 'path'
import 'dotenv/config'

// ─── Constants ────────────────────────────────────────────────────────────────

const TRON_SHASTA_CHAIN_ID = 2494104990

// ─── Utilities ────────────────────────────────────────────────────────────────

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms))
}

function loadArtifact(name: string): { abi: any[]; bytecode: string } {
  const p = path.join(__dirname, '..', 'out', `${name}.sol`, `${name}.json`)
  const a = JSON.parse(fs.readFileSync(p, 'utf8'))
  const bytecode = typeof a.bytecode === 'object' ? a.bytecode.object : a.bytecode
  return { abi: a.abi, bytecode }
}

function tronAddrToHex20(tronWeb: TronWeb, addr: string): string {
  if (!addr) return ''
  if (addr.startsWith('0x')) return addr.toLowerCase()
  if (addr.startsWith('41')) return ('0x' + addr.slice(2)).toLowerCase()
  return ('0x' + (tronWeb.address.toHex(addr) as string).slice(2)).toLowerCase()
}

function hex20ToBase58(tronWeb: TronWeb, hex20: string): string {
  return tronWeb.address.fromHex('41' + hex20.slice(2)) as string
}

/**
 * Predict a CREATE2 address using a configurable prefix byte.
 * Replicates Clones.predict() in Solidity.
 */
function predictCreate2(
  deployer: string,    // 0x-prefixed hex20
  salt: string,        // bytes32 hex
  initCodeHash: string, // keccak256 of init code
  prefix: Uint8Array,
): string {
  const packed = ethers.concat([
    prefix,
    ethers.getBytes(deployer),
    ethers.getBytes(salt),
    ethers.getBytes(initCodeHash),
  ])
  return '0x' + ethers.keccak256(packed).slice(-40)
}

/**
 * Compute the keccak256 of the Proxy init code for a given implementation.
 * This matches `keccak256(abi.encodePacked(type(Proxy).creationCode, abi.encode(implementation)))`
 */
function proxyInitCodeHash(proxyCreationCode: string, implementationHex20: string): string {
  // abi.encode(address) = left-padded to 32 bytes
  const encodedImpl = ethers.AbiCoder.defaultAbiCoder().encode(['address'], [implementationHex20])
  const initCode = ethers.concat([ethers.getBytes(proxyCreationCode), ethers.getBytes(encodedImpl)])
  return ethers.keccak256(initCode)
}

// ─── ABIs & sigs ─────────────────────────────────────────────────────────────

const PUBLISH_AND_FUND_ABI = [
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

const REFUND_ABI = [
  {
    type: 'function', name: 'refund',
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
    outputs: [],
    stateMutability: 'nonpayable',
  },
]

const PUBLISH_AND_FUND_SIG =
  'publishAndFund((uint64,(bytes32,uint64,address,uint256,(address,uint256)[],(address,bytes,uint256)[]),(uint64,address,address,uint256,(address,uint256)[])),bool)'

const REFUND_SIG =
  'refund(uint64,bytes32,(uint64,address,address,uint256,(address,uint256)[]))'

const INTENT_PUBLISHED_TOPIC = ethers.id(
  'IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])',
)

async function tronSendAndWait(
  tronWeb: TronWeb,
  contractB58: string,
  funcSig: string,
  rawParameter: string,
  callValue = 0,
  feeLimit = 500_000_000,
): Promise<any> {
  const result = await tronWeb.transactionBuilder.triggerSmartContract(
    contractB58,
    funcSig,
    { feeLimit, callValue, rawParameter },
    [],
  )
  if (!result.result?.result) {
    throw new Error(`triggerSmartContract failed: ${JSON.stringify(result)}`)
  }
  const signed = await tronWeb.trx.sign(result.transaction)
  const broadcast = await tronWeb.trx.sendRawTransaction(signed)
  if (!broadcast.result) {
    throw new Error(`Broadcast failed: ${JSON.stringify(broadcast)}`)
  }
  console.log(`  txId: ${broadcast.txid}`)
  for (let i = 0; i < 20; i++) {
    await sleep(3000)
    const info: any = await tronWeb.trx.getTransactionInfo(broadcast.txid)
    if (info?.id) {
      if (info.receipt?.result !== 'SUCCESS') {
        throw new Error(`Tx reverted: ${JSON.stringify(info)}`)
      }
      return { txid: broadcast.txid, info }
    }
  }
  throw new Error(`Timed out waiting for ${broadcast.txid}`)
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  console.log('=== IntentSourceTron CREATE2 Prefix Mismatch Bug — Shasta Test ===\n')

  const rpcUrl = process.env.TRON_SHASTA_RPC_URL || 'https://api.shasta.trongrid.io'
  let privateKey = process.env.PRIVATE_KEY || ''
  if (privateKey.startsWith('0x')) privateKey = privateKey.slice(2)
  if (!privateKey) throw new Error('PRIVATE_KEY required')

  const tronWeb = new TronWeb({ fullHost: rpcUrl, privateKey })
  const deployerB58 = tronWeb.address.fromPrivateKey(privateKey) as string
  const deployerHex20 = tronAddrToHex20(tronWeb, deployerB58)
  console.log(`Deployer: ${deployerB58} (${deployerHex20})`)

  // ── Step 1: Deploy or reuse PortalTron ───────────────────────────────────

  let portalHex20: string
  let vaultImplHex20: string

  const existingPortal = process.env.TRON_PORTAL_CONTRACT || ''
  const existingVaultImpl = process.env.TRON_VAULT_IMPL || ''

  if (existingPortal && existingVaultImpl) {
    portalHex20 = tronAddrToHex20(tronWeb, existingPortal)
    vaultImplHex20 = tronAddrToHex20(tronWeb, existingVaultImpl)
    console.log(`\n[Step 1] Reusing PortalTron:    ${portalHex20}`)
    console.log(`         Reusing VaultTron impl: ${vaultImplHex20}`)
  } else {
    console.log('\n[Step 1] Deploying fresh PortalTron on Shasta...')

    const { abi, bytecode } = loadArtifact('PortalTron')
    const bytecodeHex = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode
    const deployerHex41 = tronWeb.defaultAddress.hex as string

    const tx = await tronWeb.transactionBuilder.createSmartContract(
      {
        abi,
        bytecode: bytecodeHex,
        feeLimit: 5_000_000_000,
        callValue: 0,
        userFeePercentage: 100,
        originEnergyLimit: 10_000_000,
      },
      deployerHex41,
    )
    const signed = await tronWeb.trx.sign(tx)
    const broadcast = await tronWeb.trx.sendRawTransaction(signed)
    if (!broadcast.result) throw new Error(`Portal deploy failed: ${JSON.stringify(broadcast)}`)

    console.log(`  txId: ${broadcast.txid}`)

    // Wait for confirmation and get internal transactions to find VaultTron address
    let portalInfo: any
    for (let i = 0; i < 20; i++) {
      await sleep(3000)
      portalInfo = await tronWeb.trx.getTransactionInfo(broadcast.txid)
      if (portalInfo?.id) break
    }
    if (!portalInfo?.id) throw new Error('Portal deploy timed out')
    if (portalInfo.receipt?.result !== 'SUCCESS') {
      throw new Error(`Portal deploy failed: ${JSON.stringify(portalInfo)}`)
    }

    portalHex20 = '0x' + (portalInfo.contract_address as string).slice(2)
    console.log(`  PortalTron deployed: ${portalHex20} (${hex20ToBase58(tronWeb, portalHex20)})`)

    // VaultTron is deployed inside IntentSourceTron constructor — find it in internal txs
    const internalTxs: any[] = portalInfo.internal_transactions || []
    // VaultTron is the first `new` in IntentSourceTron's constructor — first internal create
    const createTxs = internalTxs.filter(
      (t: any) => t.note === '637265617465' || t.note === 'create' || t.type === 'create',
    )
    const vaultDeploy = createTxs[0]
    if (vaultDeploy?.transferTo_address) {
      vaultImplHex20 = '0x' + (vaultDeploy.transferTo_address as string).slice(2).toLowerCase()
    } else if (existingVaultImpl) {
      vaultImplHex20 = tronAddrToHex20(tronWeb, existingVaultImpl)
    } else {
      throw new Error(
        'Could not determine VaultTron implementation address from internal txs.\n' +
          'Set TRON_VAULT_IMPL env var and retry.\n' +
          `Internal txs: ${JSON.stringify(internalTxs, null, 2)}`,
      )
    }
    console.log(`  VaultTron impl:      ${vaultImplHex20} (${hex20ToBase58(tronWeb, vaultImplHex20)})`)
  }

  // ── Step 1b: Deploy or reuse TestProver ──────────────────────────────────

  let proverHex20: string

  const existingProver = process.env.TRON_TEST_PROVER || ''
  if (existingProver) {
    proverHex20 = tronAddrToHex20(tronWeb, existingProver)
    console.log(`\n[Step 1b] Reusing TestProver: ${proverHex20}`)
  } else {
    console.log('\n[Step 1b] Deploying TestProver on Shasta...')

    const { abi: proverAbi, bytecode: proverBytecode } = loadArtifact('TestProver')
    const proverBytecodeHex = proverBytecode.startsWith('0x') ? proverBytecode.slice(2) : proverBytecode

    // TestProver constructor takes address _portal.
    // Append ABI-encoded args to bytecode and strip constructor from ABI so TronWeb
    // doesn't try to re-encode them.
    const constructorArgs = ethers.AbiCoder.defaultAbiCoder().encode(['address'], [portalHex20]).slice(2)
    const proverAbiNoConstructor = proverAbi.filter((x: any) => x.type !== 'constructor')

    const proverTx = await tronWeb.transactionBuilder.createSmartContract(
      {
        abi: proverAbiNoConstructor,
        bytecode: proverBytecodeHex + constructorArgs,
        feeLimit: 2_000_000_000,
        callValue: 0,
        userFeePercentage: 100,
        originEnergyLimit: 10_000_000,
      },
      tronWeb.defaultAddress.hex as string,
    )
    const proverSigned = await tronWeb.trx.sign(proverTx)
    const proverBroadcast = await tronWeb.trx.sendRawTransaction(proverSigned)
    if (!proverBroadcast.result) throw new Error(`TestProver deploy failed: ${JSON.stringify(proverBroadcast)}`)
    console.log(`  txId: ${proverBroadcast.txid}`)

    let proverInfo: any
    for (let i = 0; i < 20; i++) {
      await sleep(3000)
      proverInfo = await tronWeb.trx.getTransactionInfo(proverBroadcast.txid)
      if (proverInfo?.id) break
    }
    if (!proverInfo?.id) throw new Error('TestProver deploy timed out')
    if (proverInfo.receipt?.result !== 'SUCCESS') throw new Error(`TestProver deploy failed: ${JSON.stringify(proverInfo)}`)

    proverHex20 = '0x' + (proverInfo.contract_address as string).slice(2)
    console.log(`  TestProver deployed: ${proverHex20} (${hex20ToBase58(tronWeb, proverHex20)})`)
    console.log(`  Re-run with: TRON_TEST_PROVER=${hex20ToBase58(tronWeb, proverHex20)}`)
  }

  // ── Step 2: Compute predicted (0x41) vs actual (0xff) vault address ───────

  console.log('\n[Step 2] Computing vault addresses for a sample intent hash...')

  const { bytecode: proxyBytecode } = loadArtifact('Proxy')
  const proxyCreationCode = proxyBytecode.startsWith('0x') ? proxyBytecode : '0x' + proxyBytecode
  const initCodeHash = proxyInitCodeHash(proxyCreationCode, vaultImplHex20)
  console.log(`  Proxy init code hash: ${initCodeHash}`)

  // Use a deterministic sample intent hash
  const sampleIntentHash = ethers.keccak256(ethers.toUtf8Bytes('test-bug-intent-001'))
  console.log(`  Sample intent hash:   ${sampleIntentHash}`)

  const predicted041 = predictCreate2(
    portalHex20,
    sampleIntentHash,
    initCodeHash,
    new Uint8Array([0x41]),
  )
  const predicted0ff = predictCreate2(
    portalHex20,
    sampleIntentHash,
    initCodeHash,
    new Uint8Array([0xff]),
  )

  console.log(`\n  Predicted address (0x41 prefix): ${predicted041}`)
  console.log(`  Predicted address (0xff prefix): ${predicted0ff}`)
  console.log(`  Addresses match?  ${predicted041 === predicted0ff ? '✓ YES (no bug)' : '✗ NO  (BUG CONFIRMED)'}`)

  if (predicted041 === predicted0ff) {
    console.log('\n  Addresses match — bug not present on this deployment. Exiting.')
    return
  }

  // ── Step 3: Create and fund an intent using TRX as reward ─────────────────

  console.log('\n[Step 3] Creating and funding an intent with TRX reward...')

  const rewardAmount = 1_000_000n   // 1 TRX in SUN
  const destinationChainId = 10n    // dummy destination (Optimism chain id)
  const deadline = Math.floor(Date.now() / 1000) + 90  // 90 seconds

  const salt = ethers.hexlify(ethers.randomBytes(32))
  const portalB58 = hex20ToBase58(tronWeb, portalHex20)

  // Intent array — reward field order: [deadline, creator, prover, nativeAmount, tokens]
  const intent = [
    destinationChainId,
    [salt, BigInt(deadline), portalHex20, 0n, [], []],          // route
    [BigInt(deadline), deployerHex20, proverHex20, rewardAmount, []], // reward (nativeAmount = 1 TRX)
  ]

  const iface = new ethers.Interface(PUBLISH_AND_FUND_ABI)
  const calldata = iface.encodeFunctionData('publishAndFund', [intent, false])

  const { txid: fundTxid, info: fundInfo } = await tronSendAndWait(
    tronWeb, portalB58, PUBLISH_AND_FUND_SIG, calldata.slice(10),
    Number(rewardAmount), 500_000_000,
  )

  // Extract intentHash from IntentPublished event log
  let intentHash = ''
  for (const log of fundInfo.log || []) {
    if (('0x' + log.topics?.[0]) === INTENT_PUBLISHED_TOPIC) {
      intentHash = '0x' + log.topics[1]
      break
    }
  }
  if (!intentHash) throw new Error('IntentPublished event not found in logs')
  console.log(`  Intent hash: ${intentHash}`)

  // ── Step 4: Verify fund() sent TRX to the 0x41 address, not 0xff ──────────

  console.log('\n[Step 4] Checking TRX balances...')

  const vault041 = predictCreate2(portalHex20, intentHash, initCodeHash, new Uint8Array([0x41]))
  const vault0ff = predictCreate2(portalHex20, intentHash, initCodeHash, new Uint8Array([0xff]))

  console.log(`  Vault (0x41 predicted — wrong): ${vault041}`)
  console.log(`  Vault (0xff actual):            ${vault0ff}`)

  const bal041 = await tronWeb.trx.getBalance(hex20ToBase58(tronWeb, vault041))
  const bal0ff = await tronWeb.trx.getBalance(hex20ToBase58(tronWeb, vault0ff))

  console.log(`\n  TRX at 0x41 address: ${bal041} SUN  (${Number(bal041) / 1e6} TRX)`)
  console.log(`  TRX at 0xff address: ${bal0ff} SUN  (${Number(bal0ff) / 1e6} TRX)`)

  if (BigInt(bal041) >= rewardAmount) {
    console.log(`\n  ⚠  BUG CONFIRMED: ${rewardAmount} SUN sent to 0x41 address (no code, never deployed)`)
  } else if (BigInt(bal0ff) >= rewardAmount) {
    console.log(`\n  ✓  Funds at 0xff address — bug not triggered`)
  } else {
    console.log(`\n  ?: Funds at neither address — check manually`)
  }

  // ── Step 5: Wait for deadline, then refund — show funds remain stuck ───────

  const waitMs = Math.max((deadline - Math.floor(Date.now() / 1000) + 3) * 1000, 0)
  if (waitMs > 0) {
    console.log(`\n[Step 5] Waiting ${Math.ceil(waitMs / 1000)}s for deadline...`)
    await sleep(waitMs)
  } else {
    console.log('\n[Step 5] Deadline passed, attempting refund...')
  }

  const deployerBalBefore = await tronWeb.trx.getBalance(deployerB58)
  console.log(`  Deployer TRX before refund: ${deployerBalBefore} SUN`)

  // Compute routeHash = keccak256(abi.encode(route))
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()
  const routeEncoded = abiCoder.encode(
    ['tuple(bytes32 salt, uint64 deadline, address portal, uint256 nativeAmount, tuple(address token, uint256 amount)[] tokens, tuple(address target, bytes data, uint256 value)[] calls)'],
    [{ salt, deadline: BigInt(deadline), portal: portalHex20, nativeAmount: 0n, tokens: [], calls: [] }],
  )
  const routeHash = ethers.keccak256(routeEncoded)

  const reward = [BigInt(deadline), deployerHex20, proverHex20, rewardAmount, []]
  const refundCalldata = new ethers.Interface(REFUND_ABI).encodeFunctionData('refund', [
    destinationChainId, routeHash, reward,
  ])

  let refundStatus = 'unknown'
  try {
    const { info: refundInfo } = await tronSendAndWait(
      tronWeb, portalB58, REFUND_SIG, refundCalldata.slice(10),
    )
    refundStatus = refundInfo.receipt?.result
  } catch (e: any) {
    refundStatus = `REVERTED (${e.message?.slice(0, 80)})`
  }

  const deployerBalAfter = await tronWeb.trx.getBalance(deployerB58)
  const bal041After = await tronWeb.trx.getBalance(hex20ToBase58(tronWeb, vault041))
  const bal0ffAfter = await tronWeb.trx.getBalance(hex20ToBase58(tronWeb, vault0ff))

  console.log(`  Refund tx status:                  ${refundStatus}`)
  console.log(`  Deployer TRX after refund:         ${deployerBalAfter} SUN`)
  console.log(`  TRX at 0x41 address after refund:  ${bal041After} SUN`)
  console.log(`  TRX at 0xff address after refund:  ${bal0ffAfter} SUN`)

  const refundReceived = BigInt(deployerBalAfter) > BigInt(deployerBalBefore)
  const fundsStuck = BigInt(bal041After) >= rewardAmount

  // ── Summary ───────────────────────────────────────────────────────────────

  console.log('\n=== Summary ===')
  console.log(`  Portal:                       ${portalHex20}`)
  console.log(`  VaultTron impl:               ${vaultImplHex20}`)
  console.log(`  Intent hash:                  ${intentHash}`)
  console.log(`  Vault (0x41, predicted):      ${vault041}`)
  console.log(`  Vault (0xff, deployed):       ${vault0ff}`)
  console.log(`  Addresses differ:             ${vault041 !== vault0ff}`)
  console.log(`  Funds sent to wrong address:  ${BigInt(bal041) >= rewardAmount}`)
  console.log(`  Refund returned funds:        ${refundReceived}`)
  console.log(`  Funds stuck after refund:     ${fundsStuck}`)

  if (vault041 !== vault0ff && fundsStuck && !refundReceived) {
    console.log('\n  ⚠  BUG FULLY CONFIRMED on Shasta.')
    console.log(`      ${rewardAmount} SUN permanently stuck at ${vault041}`)
  }
}

main().catch((err) => {
  console.error(err)
  process.exitCode = 1
})
