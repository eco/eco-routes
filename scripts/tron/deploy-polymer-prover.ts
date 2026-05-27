/**
 * deploy-polymer-prover.ts
 *
 * Deploys PolymerProver to Base and/or Tron via CREATE3 on both chains.
 * CREATE3 addresses depend only on salt + deployer — not bytecode — so both
 * sides can be predicted before either is deployed, eliminating the whitelist
 * circular dependency.
 *
 * Required env vars:
 *   PRIVATE_KEY                     secp256k1 private key (hex, with or without 0x)
 *   ALCHEMY_API_KEY                 Alchemy API key (used to build Base RPC URL)
 *   TRON_MAINNET_RPC_URL            Tron full-node RPC
 *   PORTAL_CONTRACT                 Portal address on Base
 *   TRON_PORTAL_CONTRACT            Portal address on Tron (base58 or hex)
 *   POLYMER_CROSS_L2_PROVER_V2      CrossL2ProverV2 on Base
 *   TRON_POLYMER_CROSS_L2_PROVER_V2 CrossL2ProverV2 on Tron (base58 or hex)
 *   SALT                            deployment salt (string or bytes32 hex)
 *
 * Optional env vars:
 *   POLYMER_MAX_LOG_DATA_SIZE       max encodedProofs bytes (default: 32768)
 *   CREATE3_DEPLOYER                CREATE3 factory on Base (default: 0xC6BAd...)
 *   TRON_CREATE3_DEPLOYER           CREATE3 factory on Tron (base58)
 *   BASE_POLYMER_PROVER             skip Base deploy, reuse this address
 *   TRON_POLYMER_PROVER             skip Tron deploy, reuse this address (base58 or hex)
 *
 * Usage:
 *   # Dry run — predict addresses, no transactions
 *   npx ts-node scripts/tron/deploy-polymer-prover.ts --dry-run
 *
 *   # Deploy to Base only
 *   npx ts-node scripts/tron/deploy-polymer-prover.ts --chains base
 *
 *   # Deploy to both
 *   npx ts-node scripts/tron/deploy-polymer-prover.ts --chains base,tron
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

function alchemyBaseRpc(apiKey: string): string {
  return `https://base-mainnet.g.alchemy.com/v2/${apiKey}`
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

async function deployEvmPolymerProver(opts: {
  rpcUrl: string
  privateKey: string
  portal: string
  crossL2ProverV2: string
  maxLogDataSize: number
  whitelist: string[]
  salt: string
  create3Deployer: string
  predicted: string
  dryRun: boolean
}): Promise<void> {
  const tag = '[Base]'

  if (opts.dryRun) {
    console.log(`  ${tag} [dry-run] skipping deployment`)
    return
  }

  const provider = new ethers.JsonRpcProvider(opts.rpcUrl)
  const wallet = new ethers.Wallet(opts.privateKey, provider)

  const code = await provider.getCode(opts.predicted)
  if (code !== '0x') {
    console.log(`  ${tag} Already deployed at ${opts.predicted}`)
    return
  }

  const initCode = buildInitCode(
    opts.portal, opts.crossL2ProverV2, opts.maxLogDataSize, opts.whitelist,
  )

  const create3 = new ethers.Contract(opts.create3Deployer, CREATE3_ABI, wallet)
  console.log(`  ${tag} Deploying via CREATE3...`)
  const tx = await create3.deploy(initCode, opts.salt)
  const receipt = await tx.wait()

  const finalCode = await provider.getCode(opts.predicted)
  if (finalCode === '0x') throw new Error(`${tag} Deploy verification failed (tx: ${receipt.hash})`)
  console.log(`  ${tag} Deployed: ${opts.predicted} (tx: ${receipt.hash})`)
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

async function deployTronPolymerProver(opts: {
  tw: TronWeb
  factoryBase58: string
  salt: string
  portal: string
  crossL2ProverV2: string
  maxLogDataSize: number
  whitelist: string[]
  addrBase58: string
  dryRun: boolean
}): Promise<void> {
  const tag = '[Tron]'

  if (opts.dryRun) {
    console.log(`  ${tag} [dry-run] skipping deployment`)
    return
  }

  const existingCode = await opts.tw.trx.getContract(opts.addrBase58).catch(() => null)
  if (existingCode?.bytecode) {
    console.log(`  ${tag} Already deployed at ${opts.addrBase58}`)
    return
  }

  const portal20 = tronAddrToHex20(opts.tw, opts.portal)
  const crossL2Prover20 = tronAddrToHex20(opts.tw, opts.crossL2ProverV2)
  const initCode = buildInitCode(portal20, crossL2Prover20, opts.maxLogDataSize, opts.whitelist)

  const rawParameter = abiCoder.encode(['bytes', 'bytes32'], [initCode, opts.salt]).slice(2)
  const result = await opts.tw.transactionBuilder.triggerSmartContract(
    opts.factoryBase58,
    'deploy(bytes,bytes32)',
    { feeLimit: 2_000_000_000, callValue: 0, rawParameter },
    [],
  )
  const signed = await opts.tw.trx.sign(result.transaction)
  const broadcast = await opts.tw.trx.sendRawTransaction(signed)

  if (!broadcast.result) throw new Error(`${tag} Broadcast failed: ${JSON.stringify(broadcast)}`)

  console.log(`  ${tag} Deploy tx: ${broadcast.txid} — polling...`)
  for (let i = 0; i < 30; i++) {
    await sleep(3000)
    const info: any = await opts.tw.trx.getTransactionInfo(broadcast.txid)
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
    'base,tron'
  const chains = chainsArg.split(',').map((s) => s.trim().toLowerCase())

  const doBase = chains.includes('base')
  const doTron = chains.includes('tron')
  if (!doBase && !doTron) throw new Error('No recognised chains. Use --chains base,tron')

  // ── Env ───────────────────────────────────────────────────────────────────
  const pk = process.env.PRIVATE_KEY
  if (!pk) throw new Error('PRIVATE_KEY not set')
  const privateKey = pk.startsWith('0x') ? pk.slice(2) : pk

  const alchemyKey = process.env.ALCHEMY_API_KEY
  if (!alchemyKey) throw new Error('ALCHEMY_API_KEY not set')
  const baseRpc = alchemyBaseRpc(alchemyKey)

  const tronRpc = process.env.TRON_MAINNET_RPC_URL
  if (!tronRpc) throw new Error('TRON_MAINNET_RPC_URL not set')

  const rawSalt = process.env.SALT ?? 'PolymerProver'
  const polymerSalt = deriveSalt(rawSalt, 'POLYMER_PROVER')
  const maxLogDataSize = parseInt(process.env.POLYMER_MAX_LOG_DATA_SIZE ?? '32768', 10)
  const create3Deployer = process.env.CREATE3_DEPLOYER ?? DEFAULT_CREATE3_DEPLOYER

  const tronCreate3 = process.env.TRON_CREATE3_DEPLOYER
  if (doTron && !tronCreate3) throw new Error('TRON_CREATE3_DEPLOYER not set')

  // ── Step 1: predict both addresses ───────────────────────────────────────
  // CREATE3 on both chains: address = f(salt, deployer), bytecode-independent.
  // Both can be predicted upfront with no circular dependency.

  console.log('\n── Address Prediction ────────────────────────────────────────')

  let baseAddr = process.env.BASE_POLYMER_PROVER ?? ''
  let tronAddr20 = ''
  let tronAddrBase58 = process.env.TRON_POLYMER_PROVER ?? ''

  const wallet = new ethers.Wallet('0x' + privateKey)

  if (doBase && !baseAddr) {
    const provider = new ethers.JsonRpcProvider(baseRpc)
    baseAddr = await predictEvmAddress(create3Deployer, wallet.address, polymerSalt, provider)
  }
  if (baseAddr) console.log(`  [Base]  PolymerProver: ${baseAddr}`)

  if (doTron && !tronAddrBase58) {
    const tw = new TronWeb({ fullHost: tronRpc, privateKey })
    const deployerHex20 = tronAddrToHex20(tw, tw.address.fromPrivateKey(privateKey) as string)
    const predicted = await predictTronAddress(tw, tronCreate3!, deployerHex20, polymerSalt)
    tronAddr20 = predicted.addr20hex
    tronAddrBase58 = predicted.addrBase58
  } else if (tronAddrBase58) {
    const tw = new TronWeb({ fullHost: tronRpc, privateKey })
    tronAddr20 = tronAddrToHex20(tw, tronAddrBase58)
  }
  if (tronAddrBase58) console.log(`  [Tron]  PolymerProver: ${tronAddrBase58} (${tronAddr20})`)

  // ── Step 2: build whitelists ──────────────────────────────────────────────
  const baseWhitelist = tronAddr20 ? [hex20ToBytes32(tronAddr20)] : []
  const tronWhitelist = baseAddr ? [hex20ToBytes32(baseAddr)] : []

  console.log('\n── Whitelists ────────────────────────────────────────────────')
  if (doBase) console.log(`  [Base]  ${JSON.stringify(baseWhitelist)}`)
  if (doTron) console.log(`  [Tron]  ${JSON.stringify(tronWhitelist)}`)

  // ── Step 3: deploy ────────────────────────────────────────────────────────
  console.log('\n── Deployment ────────────────────────────────────────────────')

  if (doBase) {
    const portal = process.env.PORTAL_CONTRACT
    if (!portal) throw new Error('PORTAL_CONTRACT not set')
    const crossL2 = process.env.POLYMER_CROSS_L2_PROVER_V2
    if (!crossL2) throw new Error('POLYMER_CROSS_L2_PROVER_V2 not set')

    await deployEvmPolymerProver({
      rpcUrl: baseRpc,
      privateKey: '0x' + privateKey,
      portal,
      crossL2ProverV2: crossL2,
      maxLogDataSize,
      whitelist: baseWhitelist,
      salt: polymerSalt,
      create3Deployer,
      predicted: baseAddr,
      dryRun,
    })
  }

  if (doTron) {
    const tronPortal = process.env.TRON_PORTAL_CONTRACT
    if (!tronPortal) throw new Error('TRON_PORTAL_CONTRACT not set')
    const tronCrossL2 = process.env.TRON_POLYMER_CROSS_L2_PROVER_V2
    if (!tronCrossL2) throw new Error('TRON_POLYMER_CROSS_L2_PROVER_V2 not set')

    const tw = new TronWeb({ fullHost: tronRpc, privateKey })
    await deployTronPolymerProver({
      tw,
      factoryBase58: tronCreate3!,
      salt: polymerSalt,
      portal: tronPortal,
      crossL2ProverV2: tronCrossL2,
      maxLogDataSize,
      whitelist: tronWhitelist,
      addrBase58: tronAddrBase58,
      dryRun,
    })
  }

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log('\n── Summary ───────────────────────────────────────────────────')
  if (doBase) console.log(`  Base  PolymerProver : ${baseAddr}`)
  if (doTron) console.log(`  Tron  PolymerProver : ${tronAddrBase58} (${tronAddr20})`)
  console.log(`  Salt (bytes32)      : ${polymerSalt}`)
  console.log(`  maxLogDataSize      : ${maxLogDataSize}`)
  if (dryRun) console.log('\n  [dry-run] No transactions were sent.')
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
