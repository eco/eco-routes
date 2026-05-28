/**
 * deploy-polymer-prover.ts
 *
 * Deploys PolymerProver to one or more EVM chains and optionally Tron via CREATE3.
 * All EVM deployments share the same deterministic address (same salt + deployer).
 *
 * Whitelist logic:
 *   EVM provers : [bytes32(tronProverAddr), bytes32(evmProverAddr)]
 *   Tron prover : [bytes32(evmProverAddr)]
 *
 * Per-chain env vars (replace {CHAIN} with upper-case chain ID, e.g. BASE, OP):
 *   {CHAIN}_RPC_URL                     RPC endpoint
 *   {CHAIN}_PORTAL_CONTRACT             Portal address
 *   {CHAIN}_POLYMER_CROSS_L2_PROVER_V2  CrossL2ProverV2 address
 *   {CHAIN}_POLYMER_PROVER              (optional) skip deploy, reuse this address
 *
 * Tron env vars:
 *   TRON_RPC_URL
 *   TRON_PORTAL_CONTRACT
 *   TRON_POLYMER_CROSS_L2_PROVER_V2
 *   TRON_CREATE3_DEPLOYER
 *   TRON_POLYMER_PROVER                 (optional) skip deploy, reuse this address
 *
 * Shared env vars:
 *   PRIVATE_KEY                  secp256k1 private key (hex, with or without 0x)
 *   SALT                         deployment salt (string or bytes32 hex)
 *   CREATE3_DEPLOYER             CREATE3 factory on EVM chains (default: 0xC6BAd...)
 *   POLYMER_MAX_LOG_DATA_SIZE    max encodedProofs bytes (default: 32768)
 *
 * Usage:
 *   # Predict addresses only — no transactions
 *   npx ts-node scripts/tron/deploy-polymer-prover.ts --dry-run
 *
 *   # Deploy to specific chains
 *   npx ts-node scripts/tron/deploy-polymer-prover.ts --chains base,op,tron
 *
 *   # Deploy EVM only
 *   npx ts-node scripts/tron/deploy-polymer-prover.ts --chains base,op
 *
 * Before running:
 *   forge build
 */

import { TronWeb } from 'tronweb'
import { ethers } from 'ethers'
import fs from 'fs'
import path from 'path'
import 'dotenv/config'

// ─── Constants ────────────────────────────────────────────────────────────────

const DEFAULT_CREATE3_DEPLOYER = '0xC6BAd1EbAF366288dA6FB5689119eDd695a66814'

const CREATE3_ABI = [
  'function deploy(bytes memory bytecode, bytes32 salt) external payable returns (address deployedAddress_)',
  'function deployedAddress(bytes memory bytecode, address sender, bytes32 salt) external view returns (address)',
]

const CONSTRUCTOR_TYPES = ['address', 'address', 'uint256', 'bytes32[]']

const abiCoder = ethers.AbiCoder.defaultAbiCoder()

// ─── Types ────────────────────────────────────────────────────────────────────

type EvmChain = {
  id: string        // short key passed to --chains, e.g. 'base', 'op'
  label: string     // display label
  rpcUrl: string
  portal: string
  crossL2Prover: string
  reuseAddr: string // hex20, empty = deploy fresh
}

// ─── Utilities ────────────────────────────────────────────────────────────────

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function loadArtifact(contractName: string): { abi: any[]; bytecode: string } {
  const artifactPath = path.join(
    __dirname, '../..', 'out', `${contractName}.sol`, `${contractName}.json`,
  )
  if (!fs.existsSync(artifactPath)) {
    throw new Error(`Artifact not found: ${artifactPath}. Run \`forge build\` first.`)
  }
  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'))
  const bytecode =
    typeof artifact.bytecode === 'object' ? artifact.bytecode.object : artifact.bytecode
  return { abi: artifact.abi, bytecode }
}

function toBytes32Salt(salt: string): string {
  if (ethers.isHexString(salt, 32)) return salt
  return ethers.id(salt)
}

function deriveSalt(baseSalt: string, label: string): string {
  return ethers.keccak256(
    ethers.concat([ethers.getBytes(toBytes32Salt(baseSalt)), ethers.toUtf8Bytes(label)]),
  )
}

function tronAddrToHex20(tw: TronWeb, addr: string): string {
  if (!addr) return ''
  if (addr.startsWith('0x')) return addr.toLowerCase()
  if (addr.startsWith('41')) return ('0x' + addr.slice(2)).toLowerCase()
  return ('0x' + (tw.address.toHex(addr) as string).slice(2)).toLowerCase()
}

function hex20ToBytes32(hex20: string): string {
  const clean = hex20.startsWith('0x') ? hex20.slice(2) : hex20
  return '0x' + clean.padStart(64, '0')
}

function buildInitCode(
  portal: string,
  crossL2Prover: string,
  maxLogDataSize: number,
  whitelist: string[],
): string {
  const { bytecode } = loadArtifact('PolymerProver')
  const creationCode = bytecode.startsWith('0x') ? bytecode : '0x' + bytecode
  const constructorArgs = abiCoder.encode(CONSTRUCTOR_TYPES, [
    portal, crossL2Prover, maxLogDataSize, whitelist,
  ])
  return ethers.hexlify(
    ethers.concat([ethers.getBytes(creationCode), ethers.getBytes(constructorArgs)]),
  )
}

/** Read required per-chain env vars and return an EvmChain config. */
function resolveEvmChain(id: string): EvmChain {
  const upper = id.toUpperCase()
  const require = (key: string): string => {
    const v = process.env[key]
    if (!v) throw new Error(`Missing env var: ${key} (required for chain '${id}')`)
    return v
  }
  return {
    id,
    label: id.charAt(0).toUpperCase() + id.slice(1),
    rpcUrl: require(`${upper}_RPC_URL`),
    portal: require(`${upper}_PORTAL_CONTRACT`),
    crossL2Prover: require(`${upper}_POLYMER_CROSS_L2_PROVER_V2`),
    reuseAddr: process.env[`${upper}_POLYMER_PROVER`] ?? '',
  }
}

// ─── EVM ──────────────────────────────────────────────────────────────────────

async function predictEvmAddress(
  create3Deployer: string,
  deployer: string,
  salt: string,
  provider: ethers.JsonRpcProvider,
): Promise<string> {
  const create3 = new ethers.Contract(create3Deployer, CREATE3_ABI, provider)
  return await create3.deployedAddress('0x', deployer, salt)
}

async function deployEvmChain(
  chain: EvmChain,
  opts: {
    privateKey: string
    evmProverAddr: string
    tronProverAddr20: string
    maxLogDataSize: number
    salt: string
    create3Deployer: string
    dryRun: boolean
  },
): Promise<void> {
  const tag = `[${chain.label}]`

  if (chain.reuseAddr) {
    console.log(`  ${tag} Reusing: ${chain.reuseAddr}`)
    return
  }

  if (opts.dryRun) {
    console.log(`  ${tag} [dry-run] skipping deployment`)
    return
  }

  const provider = new ethers.JsonRpcProvider(chain.rpcUrl)
  const wallet = new ethers.Wallet(opts.privateKey, provider)

  const code = await provider.getCode(opts.evmProverAddr)
  if (code !== '0x') {
    console.log(`  ${tag} Already deployed at ${opts.evmProverAddr}`)
    return
  }

  // Whitelist: tron prover + this EVM prover address (same on all EVM chains)
  const whitelist: string[] = []
  if (opts.tronProverAddr20) whitelist.push(hex20ToBytes32(opts.tronProverAddr20))
  whitelist.push(hex20ToBytes32(opts.evmProverAddr))

  const initCode = buildInitCode(chain.portal, chain.crossL2Prover, opts.maxLogDataSize, whitelist)
  const create3 = new ethers.Contract(opts.create3Deployer, CREATE3_ABI, wallet)

  console.log(`  ${tag} Deploying via CREATE3...`)
  const tx = await create3.deploy(initCode, opts.salt)
  const receipt = await tx.wait()

  const finalCode = await provider.getCode(opts.evmProverAddr)
  if (finalCode === '0x') throw new Error(`${tag} Deploy verification failed (tx: ${receipt.hash})`)
  console.log(`  ${tag} Deployed: ${opts.evmProverAddr}  (tx: ${receipt.hash})`)
}

// ─── Tron ─────────────────────────────────────────────────────────────────────

async function predictTronAddress(
  tw: TronWeb,
  factoryBase58: string,
  deployerHex20: string,
  salt: string,
): Promise<{ addr20hex: string; addrBase58: string }> {
  const rawParameter = abiCoder.encode(
    ['bytes', 'address', 'bytes32'],
    ['0x', deployerHex20, salt],
  ).slice(2)

  const result: any = await tw.transactionBuilder.triggerConstantContract(
    factoryBase58,
    'deployedAddress(bytes,address,bytes32)',
    { rawParameter },
    [],
    tw.defaultAddress.hex,
  )

  const addr20hex = '0x' + result.constant_result[0].slice(-40)
  const addrBase58 = tw.address.fromHex('41' + addr20hex.slice(2)) as string
  return { addr20hex, addrBase58 }
}

async function deployTronChain(
  tw: TronWeb,
  opts: {
    factoryBase58: string
    salt: string
    portal: string
    crossL2ProverV2: string
    evmProverAddr: string
    maxLogDataSize: number
    addrBase58: string
    dryRun: boolean
  },
): Promise<void> {
  const tag = '[Tron]'

  if (opts.dryRun) {
    console.log(`  ${tag} [dry-run] skipping deployment`)
    return
  }

  const existingCode = await tw.trx.getContract(opts.addrBase58).catch(() => null)
  if (existingCode?.bytecode) {
    console.log(`  ${tag} Already deployed at ${opts.addrBase58}`)
    return
  }

  const portal20 = tronAddrToHex20(tw, opts.portal)
  const crossL2Prover20 = tronAddrToHex20(tw, opts.crossL2ProverV2)

  // Whitelist: just the shared EVM prover address
  const whitelist = opts.evmProverAddr ? [hex20ToBytes32(opts.evmProverAddr)] : []

  const initCode = buildInitCode(portal20, crossL2Prover20, opts.maxLogDataSize, whitelist)

  const rawParameter = abiCoder.encode(['bytes', 'bytes32'], [initCode, opts.salt]).slice(2)
  const result = await tw.transactionBuilder.triggerSmartContract(
    opts.factoryBase58,
    'deploy(bytes,bytes32)',
    { feeLimit: 2_000_000_000, callValue: 0, rawParameter },
    [],
  )
  const signed = await tw.trx.sign(result.transaction)
  const broadcast = await tw.trx.sendRawTransaction(signed)

  if (!broadcast.result) throw new Error(`${tag} Broadcast failed: ${JSON.stringify(broadcast)}`)

  console.log(`  ${tag} Deploy tx: ${broadcast.txid} — polling...`)
  for (let i = 0; i < 30; i++) {
    await sleep(3000)
    const info: any = await tw.trx.getTransactionInfo(broadcast.txid)
    if (info?.id) {
      if (info.receipt?.result !== 'SUCCESS') throw new Error(`${tag} Reverted: ${JSON.stringify(info)}`)
      console.log(`  ${tag} Deployed: ${opts.addrBase58}`)
      return
    }
  }
  throw new Error(`${tag} Timed out — txid: ${broadcast.txid}`)
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const args = process.argv.slice(2)
  const dryRun = args.includes('--dry-run')
  const chainsArg =
    args.find((a) => a.startsWith('--chains='))?.split('=')[1] ??
    args[args.indexOf('--chains') + 1] ??
    'tron'
  const chainIds = chainsArg.split(',').map((s) => s.trim().toLowerCase())

  const doTron = chainIds.includes('tron')
  const evmIds = chainIds.filter((id) => id !== 'tron')
  if (evmIds.length === 0 && !doTron) throw new Error('No chains specified.')

  // ── Env ───────────────────────────────────────────────────────────────────
  const pk = process.env.PRIVATE_KEY
  if (!pk) throw new Error('PRIVATE_KEY not set')
  const privateKey = pk.startsWith('0x') ? pk : '0x' + pk

  const rawSalt = process.env.SALT ?? 'PolymerProver'
  const polymerSalt = deriveSalt(rawSalt, 'POLYMER_PROVER')
  const maxLogDataSize = parseInt(process.env.POLYMER_MAX_LOG_DATA_SIZE ?? '32768', 10)
  const create3Deployer = process.env.CREATE3_DEPLOYER ?? DEFAULT_CREATE3_DEPLOYER

  // ── Resolve EVM chain configs ─────────────────────────────────────────────
  const evmChains: EvmChain[] = evmIds.map(resolveEvmChain)

  // ── Step 1: predict addresses ─────────────────────────────────────────────
  console.log('\n── Address Prediction ────────────────────────────────────────')

  // All EVM chains share one address — predict once from any chain's provider
  let evmProverAddr = ''
  if (evmChains.length > 0) {
    const firstReuse = evmChains.find((c) => c.reuseAddr)
    if (firstReuse) {
      evmProverAddr = firstReuse.reuseAddr
    } else {
      const wallet = new ethers.Wallet(privateKey)
      const provider = new ethers.JsonRpcProvider(evmChains[0].rpcUrl)
      evmProverAddr = await predictEvmAddress(create3Deployer, wallet.address, polymerSalt, provider)
    }
    console.log(`  [EVM]   PolymerProver: ${evmProverAddr}  (shared across: ${evmIds.join(', ')})`)
  }

  let tronAddr20 = ''
  let tronAddrBase58 = process.env.TRON_POLYMER_PROVER ?? ''
  let tw: TronWeb | null = null

  if (doTron) {
    const tronRpc = process.env.TRON_RPC_URL
    if (!tronRpc) throw new Error('TRON_RPC_URL not set')
    const tronCreate3 = process.env.TRON_CREATE3_DEPLOYER
    if (!tronCreate3) throw new Error('TRON_CREATE3_DEPLOYER not set')

    tw = new TronWeb({ fullHost: tronRpc, privateKey: privateKey.slice(2) })

    if (tronAddrBase58) {
      tronAddr20 = tronAddrToHex20(tw, tronAddrBase58)
    } else {
      const deployerHex20 = tronAddrToHex20(tw, tw.address.fromPrivateKey(privateKey.slice(2)) as string)
      const predicted = await predictTronAddress(tw, tronCreate3, deployerHex20, polymerSalt)
      tronAddr20 = predicted.addr20hex
      tronAddrBase58 = predicted.addrBase58
    }
    console.log(`  [Tron]  PolymerProver: ${tronAddrBase58}  (${tronAddr20})`)
  }

  // ── Step 2: print whitelists ──────────────────────────────────────────────
  console.log('\n── Whitelists ────────────────────────────────────────────────')
  if (evmChains.length > 0) {
    const evmWl = [
      ...(tronAddr20 ? [`bytes32(${tronAddr20})`] : []),
      `bytes32(${evmProverAddr})`,
    ]
    console.log(`  [EVM]   ${JSON.stringify(evmWl)}`)
  }
  if (doTron) {
    const tronWl = evmProverAddr ? [`bytes32(${evmProverAddr})`] : []
    console.log(`  [Tron]  ${JSON.stringify(tronWl)}`)
  }

  // ── Step 3: deploy ────────────────────────────────────────────────────────
  console.log('\n── Deployment ────────────────────────────────────────────────')

  for (const chain of evmChains) {
    await deployEvmChain(chain, {
      privateKey,
      evmProverAddr,
      tronProverAddr20: tronAddr20,
      maxLogDataSize,
      salt: polymerSalt,
      create3Deployer,
      dryRun,
    })
  }

  if (doTron && tw) {
    const tronCreate3 = process.env.TRON_CREATE3_DEPLOYER!
    const tronPortal = process.env.TRON_PORTAL_CONTRACT
    if (!tronPortal) throw new Error('TRON_PORTAL_CONTRACT not set')
    const tronCrossL2 = process.env.TRON_POLYMER_CROSS_L2_PROVER_V2
    if (!tronCrossL2) throw new Error('TRON_POLYMER_CROSS_L2_PROVER_V2 not set')

    await deployTronChain(tw, {
      factoryBase58: tronCreate3,
      salt: polymerSalt,
      portal: tronPortal,
      crossL2ProverV2: tronCrossL2,
      evmProverAddr,
      maxLogDataSize,
      addrBase58: tronAddrBase58,
      dryRun,
    })
  }

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log('\n── Summary ───────────────────────────────────────────────────')
  for (const chain of evmChains) {
    console.log(`  ${chain.label.padEnd(12)} PolymerProver : ${evmProverAddr}`)
  }
  if (doTron) {
    console.log(`  ${'Tron'.padEnd(12)} PolymerProver : ${tronAddrBase58}  (${tronAddr20})`)
  }
  console.log(`  Salt (bytes32)      : ${polymerSalt}`)
  console.log(`  maxLogDataSize      : ${maxLogDataSize}`)
  if (dryRun) console.log('\n  [dry-run] No transactions were sent.')
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
