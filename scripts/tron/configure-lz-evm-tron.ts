/**
 * configure-lz-evm-tron.ts
 *
 * Configures the LayerZero OApp settings for any EVM ↔ Tron route on both sides.
 * Pass EVM and Tron chain IDs as positional arguments. RPC URLs are built from
 * Alchemy (EVM) / TronGrid (Tron) automatically. Library addresses, executor,
 * and DVNs are resolved from docs/lzDeployments.json.
 *
 * Steps:
 *   EVM: setSendLibrary, setReceiveLibrary, setConfig(ULN send), setConfig(executor), setConfig(ULN recv)
 *   Tron: setSendLibrary, setReceiveLibrary, setConfig(ULN send), setConfig(ULN recv)
 *
 * Usage:
 *   PRIVATE_KEY=... ALCHEMY_KEY=... \
 *     npx ts-node scripts/configure-lz-evm-tron.ts <evmChainId> [tronChainId]
 *
 * Examples:
 *   # Base mainnet ↔ Tron mainnet
 *   npx ts-node scripts/configure-lz-evm-tron.ts 8453
 *
 *   # Base Sepolia ↔ Tron Shasta
 *   npx ts-node scripts/configure-lz-evm-tron.ts 84532 2494104990
 *
 * Required env vars:
 *   PRIVATE_KEY   — deployer private key (hex, with or without 0x)
 *   ALCHEMY_KEY   — Alchemy API key for EVM RPC
 *
 * Optional env vars:
 *   EVM_LZ_PROVER      — EVM LZ Prover address (hex20)
 *   TRON_LZ_PROVER     — Tron LZ Prover address (base58)
 *   TRON_LZ_PROVER_HEX — Tron LZ Prover address (hex20)
 */

import * as fs from 'fs'
import * as path from 'path'
import { ethers } from 'ethers'
import { TronWeb } from 'tronweb'
import 'dotenv/config'

// ─── Chain ID → LZ EID ────────────────────────────────────────────────────────

const CHAIN_ID_TO_EID: Record<number, number> = {
  1:          30101, // Ethereum mainnet
  10:         30111, // Optimism
  137:        30109, // Polygon
  8453:       30184, // Base
  42161:      30110, // Arbitrum One
  84532:      40245, // Base Sepolia
  11155111:   40161, // Ethereum Sepolia
  728126428:  30420, // Tron mainnet
  2494104990: 40420, // Tron Shasta
}

// ─── RPC URLs ─────────────────────────────────────────────────────────────────

const ALCHEMY_SLUGS: Record<number, string> = {
  1:        'eth-mainnet',
  10:       'opt-mainnet',
  137:      'polygon-mainnet',
  8453:     'base-mainnet',
  42161:    'arb-mainnet',
  84532:    'base-sepolia',
  11155111: 'eth-sepolia',
}

const TRON_RPC_URLS: Record<number, string> = {
  728126428:  'https://api.trongrid.io',
  2494104990: 'https://api.shasta.trongrid.io',
}

function evmRpcUrl(chainId: number, alchemyKey: string): string {
  const slug = ALCHEMY_SLUGS[chainId]
  if (!slug) throw new Error(`No Alchemy RPC configured for EVM chain ID ${chainId}`)
  return `https://${slug}.g.alchemy.com/v2/${alchemyKey}`
}

function tronRpcUrl(chainId: number): string {
  const url = TRON_RPC_URLS[chainId]
  if (!url) throw new Error(`Unknown Tron chain ID ${chainId}`)
  return url
}

// ─── Mainnet DVN preference ───────────────────────────────────────────────────
// On mainnet, use a 2-of-3 optional DVN setup with the three most reputable
// DVNs common to all Tron ↔ EVM mainnet routes.
const MAINNET_PREFERRED_DVN_NAMES = ['LayerZero Labs', 'Nethermind', 'Deutsche Telekom']
const MAINNET_OPTIONAL_THRESHOLD  = 2
const TESTNET_DVN_NAME            = 'LayerZero Labs'

function isMainnet(eid: number): boolean {
  return eid < 40000
}

// ─── Prover addresses (override via env for testnet/staging) ──────────────────

const EVM_LZ_PROVER      = process.env.EVM_LZ_PROVER      || '0xf64eaca0D1cF874ea34b8E73127f0Fe535c6be41'
const TRON_LZ_PROVER     = process.env.TRON_LZ_PROVER     || 'TYeFezmGQGEJU9JzykGebuNVvtmXQPTupz'
const TRON_LZ_PROVER_HEX = process.env.TRON_LZ_PROVER_HEX || '0xf8b5348d6e1e4c47de4abc2d9946963a7a37f2c8'

// ─── Deployment JSON lookup ────────────────────────────────────────────────────

function loadDeployments(): any {
  const p = path.join(__dirname, '../..', 'docs', 'lzDeployments.json')
  return JSON.parse(fs.readFileSync(p, 'utf8'))
}

function findChainByEid(data: any, eid: number): any {
  for (const key of Object.keys(data)) {
    const chain = data[key]
    if (!Array.isArray(chain.deployments)) continue
    for (const dep of chain.deployments) {
      if (Number(dep.eid) === eid) return chain
    }
  }
  throw new Error(`EID ${eid} not found in docs/lzDeployments.json`)
}

function getV2Deployment(chain: any, eid: number): any {
  const dep = chain.deployments?.find((d: any) => Number(d.eid) === eid && d.version === 2)
  if (!dep) throw new Error(`No v2 deployment found for EID ${eid}`)
  return dep
}

interface DVNPair {
  name: string
  evmAddress: string
  tronAddress: string
}

function resolveCommonDVNs(evmChain: any, tronChain: any): DVNPair[] {
  // canonicalName → address for EVM chain (non-deprecated, first wins)
  const evmByName: Record<string, string> = {}
  for (const [addr, info] of Object.entries(evmChain.dvns || {}) as [string, any][]) {
    if (!info.deprecated && info.canonicalName && !evmByName[info.canonicalName]) {
      evmByName[info.canonicalName] = addr
    }
  }

  const pairs: DVNPair[] = []
  for (const [addr, info] of Object.entries(tronChain.dvns || {}) as [string, any][]) {
    if (!info.deprecated && info.canonicalName && evmByName[info.canonicalName]) {
      pairs.push({ name: info.canonicalName, evmAddress: evmByName[info.canonicalName], tronAddress: addr })
    }
  }
  return pairs
}

interface ResolvedLzConfig {
  evmEid: number
  tronEid: number
  evmEndpoint: string
  evmSendLib: string
  evmRecvLib: string
  evmExecutor: string
  evmRequiredDvns: string[]
  evmOptionalDvns: string[]
  evmOptionalThreshold: number
  tronEndpoint: string
  tronSendLib: string
  tronRecvLib: string
  tronRequiredDvns: string[]
  tronOptionalDvns: string[]
  tronOptionalThreshold: number
  dvnNames: string[]
  dvnSetup: string
}

function resolveConfig(evmChainId: number, tronChainId: number): ResolvedLzConfig {
  const evmEid  = CHAIN_ID_TO_EID[evmChainId]
  const tronEid = CHAIN_ID_TO_EID[tronChainId]
  if (!evmEid)  throw new Error(`No LZ EID mapping for EVM chain ID ${evmChainId}`)
  if (!tronEid) throw new Error(`No LZ EID mapping for Tron chain ID ${tronChainId}`)

  const data      = loadDeployments()
  const evmChain  = findChainByEid(data, evmEid)
  const tronChain = findChainByEid(data, tronEid)
  const evmDep    = getV2Deployment(evmChain, evmEid)
  const tronDep   = getV2Deployment(tronChain, tronEid)

  const commonDvns = resolveCommonDVNs(evmChain, tronChain)
  if (commonDvns.length === 0) {
    throw new Error(`No common non-deprecated DVNs found between EID ${evmEid} and EID ${tronEid}`)
  }

  // Mainnet: 2-of-3 optional with the preferred DVN set
  // Testnet: all common DVNs as required (Shasta only has LZ Labs)
  let evmRequiredDvns: string[], evmOptionalDvns: string[], evmOptionalThreshold: number
  let tronRequiredDvns: string[], tronOptionalDvns: string[], tronOptionalThreshold: number
  let dvnNames: string[], dvnSetup: string

  if (isMainnet(evmEid) && isMainnet(tronEid)) {
    const preferred = commonDvns.filter(d => MAINNET_PREFERRED_DVN_NAMES.includes(d.name))
    if (preferred.length < MAINNET_PREFERRED_DVN_NAMES.length) {
      const missing = MAINNET_PREFERRED_DVN_NAMES.filter(n => !preferred.find(d => d.name === n))
      throw new Error(`Mainnet preferred DVNs not all available on this route. Missing: ${missing.join(', ')}`)
    }
    evmRequiredDvns = []; evmOptionalDvns = preferred.map(d => d.evmAddress); evmOptionalThreshold = MAINNET_OPTIONAL_THRESHOLD
    tronRequiredDvns = []; tronOptionalDvns = preferred.map(d => d.tronAddress); tronOptionalThreshold = MAINNET_OPTIONAL_THRESHOLD
    dvnNames = preferred.map(d => d.name)
    dvnSetup = `${MAINNET_OPTIONAL_THRESHOLD}-of-${preferred.length} optional`
  } else {
    const testnet = commonDvns.filter(d => d.name === TESTNET_DVN_NAME)
    if (testnet.length === 0) {
      throw new Error(`Testnet DVN '${TESTNET_DVN_NAME}' not found on this route`)
    }
    evmRequiredDvns = testnet.map(d => d.evmAddress); evmOptionalDvns = []; evmOptionalThreshold = 0
    tronRequiredDvns = testnet.map(d => d.tronAddress); tronOptionalDvns = []; tronOptionalThreshold = 0
    dvnNames = testnet.map(d => d.name)
    dvnSetup = 'required'
  }

  return {
    evmEid,
    tronEid,
    evmEndpoint:  evmDep.endpointV2.address,
    evmSendLib:   evmDep.sendUln302.address,
    evmRecvLib:   evmDep.receiveUln302.address,
    evmExecutor:  evmDep.executor.address,
    evmRequiredDvns,
    evmOptionalDvns,
    evmOptionalThreshold,
    tronEndpoint: tronDep.endpointV2.address,
    tronSendLib:  tronDep.sendUln302.address,
    tronRecvLib:  tronDep.receiveUln302.address,
    tronRequiredDvns,
    tronOptionalDvns,
    tronOptionalThreshold,
    dvnNames,
    dvnSetup,
  }
}

// ─── ABI ──────────────────────────────────────────────────────────────────────

const ENDPOINT_ABI = [
  'function setSendLibrary(address oapp, uint32 eid, address sendLib) external',
  'function setReceiveLibrary(address oapp, uint32 eid, address recvLib, uint256 gracePeriod) external',
  'function setConfig(address oapp, address lib, tuple(uint32 eid, uint32 configType, bytes config)[] params) external',
]

const TRON_ENDPOINT_IFACE = new ethers.Interface([
  'function setConfig(address oapp, address lib, tuple(uint32 eid, uint32 configType, bytes config)[] params) external',
])

// ─── Encode helpers ───────────────────────────────────────────────────────────

const CONFIG_TYPE_EXECUTOR = 1
const CONFIG_TYPE_ULN      = 2

function encodeExecutorConfig(maxMessageSize: number, executor: string): string {
  return ethers.AbiCoder.defaultAbiCoder().encode(
    ['tuple(uint32 maxMessageSize, address executorAddress)'],
    [[maxMessageSize, executor]],
  )
}

function encodeUlnConfig(
  confirmations: number,
  requiredDvns: string[],
  optionalDvns: string[],
  optionalThreshold: number,
): string {
  const sortReq = [...requiredDvns].sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()))
  const sortOpt = [...optionalDvns].sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()))
  return ethers.AbiCoder.defaultAbiCoder().encode(
    ['tuple(uint64 confirmations, uint8 requiredDVNCount, uint8 optionalDVNCount, uint8 optionalDVNThreshold, address[] requiredDVNs, address[] optionalDVNs)'],
    [[confirmations, sortReq.length, sortOpt.length, optionalThreshold, sortReq, sortOpt]],
  )
}

// ─── EVM config ───────────────────────────────────────────────────────────────

async function configureEvm(privateKey: string, rpcUrl: string, cfg: ResolvedLzConfig, chainName: string): Promise<void> {
  const provider = new ethers.JsonRpcProvider(rpcUrl)
  const wallet   = new ethers.Wallet('0x' + privateKey, provider)
  const endpoint = new ethers.Contract(cfg.evmEndpoint, ENDPOINT_ABI, wallet)

  console.log(`\n=== Configuring ${chainName} (EID ${cfg.evmEid}) → Tron (EID ${cfg.tronEid}) ===`)
  console.log(`  Wallet:   ${wallet.address}`)
  console.log(`  OApp:     ${EVM_LZ_PROVER}`)
  console.log(`  Endpoint: ${cfg.evmEndpoint}`)
  console.log(`  SendLib:  ${cfg.evmSendLib}`)
  console.log(`  RecvLib:  ${cfg.evmRecvLib}`)
  console.log(`  Executor: ${cfg.evmExecutor}`)
  console.log(`  DVNs:     ${cfg.dvnNames.join(', ')} (${cfg.dvnSetup})`)

  const trySet = async (label: string, fn: () => Promise<any>) => {
    console.log(`\n  ${label}...`)
    try {
      const tx = await fn()
      await tx.wait()
      console.log(`    tx: ${tx.hash}`)
    } catch (e: any) {
      if (e?.data === '0xd0ecb66b' || e?.message?.includes('0xd0ecb66b') || String(e).includes('0xd0ecb66b')) {
        console.log('    (already set — skipped)')
      } else {
        throw e
      }
    }
  }

  await trySet('[1/5] setSendLibrary',    () => endpoint.setSendLibrary(EVM_LZ_PROVER, cfg.tronEid, cfg.evmSendLib))
  await trySet('[2/5] setReceiveLibrary', () => endpoint.setReceiveLibrary(EVM_LZ_PROVER, cfg.tronEid, cfg.evmRecvLib, 0))

  let tx: any
  console.log('  [3/5] setConfig ULN send...')
  tx = await endpoint.setConfig(EVM_LZ_PROVER, cfg.evmSendLib, [{ eid: cfg.tronEid, configType: CONFIG_TYPE_ULN, config: encodeUlnConfig(2, cfg.evmRequiredDvns, cfg.evmOptionalDvns, cfg.evmOptionalThreshold) }])
  await tx.wait(); console.log(`    tx: ${tx.hash}`)

  console.log('  [4/5] setConfig Executor...')
  tx = await endpoint.setConfig(EVM_LZ_PROVER, cfg.evmSendLib, [{ eid: cfg.tronEid, configType: CONFIG_TYPE_EXECUTOR, config: encodeExecutorConfig(10000, cfg.evmExecutor) }])
  await tx.wait(); console.log(`    tx: ${tx.hash}`)

  console.log('  [5/5] setConfig ULN recv...')
  tx = await endpoint.setConfig(EVM_LZ_PROVER, cfg.evmRecvLib, [{ eid: cfg.tronEid, configType: CONFIG_TYPE_ULN, config: encodeUlnConfig(2, cfg.evmRequiredDvns, cfg.evmOptionalDvns, cfg.evmOptionalThreshold) }])
  await tx.wait(); console.log(`    tx: ${tx.hash}`)

  console.log(`\n  ✓ ${chainName} configuration complete`)
}

// ─── Tron config ──────────────────────────────────────────────────────────────

async function configureTron(privateKey: string, rpcUrl: string, cfg: ResolvedLzConfig, chainName: string): Promise<void> {
  const tw = new TronWeb({ fullHost: rpcUrl, privateKey })
  const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms))

  const tronEndpointB58 = tw.address.fromHex('41' + cfg.tronEndpoint.slice(2)) as string

  console.log(`\n=== Configuring Tron (EID ${cfg.tronEid}) → ${chainName} (EID ${cfg.evmEid}) ===`)
  console.log(`  Wallet:   ${tw.address.fromPrivateKey(privateKey)}`)
  console.log(`  OApp:     ${TRON_LZ_PROVER}`)
  console.log(`  Endpoint: ${tronEndpointB58}`)
  console.log(`  SendLib:  ${cfg.tronSendLib}`)
  console.log(`  RecvLib:  ${cfg.tronRecvLib}`)
  console.log(`  DVNs:     ${cfg.dvnNames.join(', ')} (${cfg.dvnSetup})`)

  const sendAndWait = async (label: string, funcSig: string, params: any[]) => {
    console.log(`\n  ${label}...`)
    const result = await tw.transactionBuilder.triggerSmartContract(
      tronEndpointB58, funcSig,
      { feeLimit: 500_000_000, callValue: 0 },
      params,
    )
    const signed    = await tw.trx.sign(result.transaction)
    const broadcast = await tw.trx.sendRawTransaction(signed)
    if (!broadcast.result) throw new Error(`Broadcast failed: ${JSON.stringify(broadcast)}`)
    console.log(`    txId: ${broadcast.txid}`)
    for (let i = 0; i < 60; i++) {
      await sleep(3000)
      const info: any = await tw.trx.getTransactionInfo(broadcast.txid)
      if (info?.id) {
        if (info.receipt?.result !== 'SUCCESS') {
          if (info.contractResult?.[0] === 'd0ecb66b') { console.log('    (already set — skipped)'); return }
          throw new Error(`Tx failed: ${JSON.stringify(info)}`)
        }
        return
      }
    }
    throw new Error(`Timed out waiting for ${broadcast.txid}`)
  }

  const sendSetConfig = async (label: string, lib: string, configParams: { eid: number; configType: number; config: string }[]) => {
    console.log(`\n  ${label}...`)
    const fullCalldata = TRON_ENDPOINT_IFACE.encodeFunctionData('setConfig', [
      TRON_LZ_PROVER_HEX,
      lib,
      configParams.map(p => [p.eid, p.configType, p.config]),
    ])
    const rawParameter = fullCalldata.slice(10)
    const result = await tw.transactionBuilder.triggerSmartContract(
      tronEndpointB58,
      'setConfig(address,address,(uint32,uint32,bytes)[])',
      { feeLimit: 500_000_000, callValue: 0, rawParameter },
      [],
    )
    const signed    = await tw.trx.sign(result.transaction)
    const broadcast = await tw.trx.sendRawTransaction(signed)
    if (!broadcast.result) throw new Error(`Broadcast failed: ${JSON.stringify(broadcast)}`)
    console.log(`    txId: ${broadcast.txid}`)
    for (let i = 0; i < 60; i++) {
      await sleep(3000)
      const info: any = await tw.trx.getTransactionInfo(broadcast.txid)
      if (info?.id) {
        if (info.receipt?.result !== 'SUCCESS') throw new Error(`Tx failed: ${JSON.stringify(info)}`)
        return
      }
    }
    throw new Error(`Timed out waiting for ${broadcast.txid}`)
  }

  await sendAndWait('[1/4] setSendLibrary', 'setSendLibrary(address,uint32,address)', [
    { type: 'address', value: TRON_LZ_PROVER },
    { type: 'uint32',  value: cfg.evmEid },
    { type: 'address', value: cfg.tronSendLib },
  ])

  await sendAndWait('[2/4] setReceiveLibrary', 'setReceiveLibrary(address,uint32,address,uint256)', [
    { type: 'address', value: TRON_LZ_PROVER },
    { type: 'uint32',  value: cfg.evmEid },
    { type: 'address', value: cfg.tronRecvLib },
    { type: 'uint256', value: 0 },
  ])

  await sendSetConfig('[3/4] setConfig ULN send', cfg.tronSendLib, [
    { eid: cfg.evmEid, configType: CONFIG_TYPE_ULN, config: encodeUlnConfig(2, cfg.tronRequiredDvns, cfg.tronOptionalDvns, cfg.tronOptionalThreshold) },
  ])

  await sendSetConfig('[4/4] setConfig ULN recv', cfg.tronRecvLib, [
    { eid: cfg.evmEid, configType: CONFIG_TYPE_ULN, config: encodeUlnConfig(2, cfg.tronRequiredDvns, cfg.tronOptionalDvns, cfg.tronOptionalThreshold) },
  ])

  console.log(`\n  ✓ Tron configuration complete`)
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const [,, evmChainIdArg, tronChainIdArg] = process.argv
  if (!evmChainIdArg) {
    console.error('Usage: npx ts-node scripts/configure-lz-evm-tron.ts <evmChainId> [tronChainId]')
    process.exitCode = 1
    return
  }

  const evmChainId  = parseInt(evmChainIdArg)
  const tronChainId = parseInt(tronChainIdArg || '728126428')

  let pk = process.env.PRIVATE_KEY || ''
  if (!pk) throw new Error('PRIVATE_KEY env var required')
  if (pk.startsWith('0x')) pk = pk.slice(2)

  const alchemyKey = process.env.ALCHEMY_KEY || ''
  if (!alchemyKey) throw new Error('ALCHEMY_KEY env var required')

  console.log(`Resolving config for EVM chain ${evmChainId} ↔ Tron chain ${tronChainId}...`)
  const cfg = resolveConfig(evmChainId, tronChainId)
  console.log(`  EVM EID:  ${cfg.evmEid}`)
  console.log(`  Tron EID: ${cfg.tronEid}`)
  console.log(`  DVNs (${cfg.dvnNames.length}, ${cfg.dvnSetup}): ${cfg.dvnNames.join(', ')}`)

  const evmRpc    = evmRpcUrl(evmChainId, alchemyKey)
  const tronRpc   = tronRpcUrl(tronChainId)
  const chainName = cfg.evmEid < 40000 ? 'EVM' : 'EVM (testnet)'

  await configureEvm(pk, evmRpc, cfg, chainName)
  await configureTron(pk, tronRpc, cfg, chainName)

  console.log('\n=== All done ===')
  console.log(`  EVM LZ Prover:  ${EVM_LZ_PROVER}`)
  console.log(`  Tron LZ Prover: ${TRON_LZ_PROVER}`)
}

main().catch(err => { console.error(err); process.exitCode = 1 })
