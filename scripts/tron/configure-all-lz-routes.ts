/**
 * configure-all-lz-routes.ts
 *
 * Reads lzdeployconfigs.json and configures LayerZero OApp settings for every
 * EVM ↔ Tron route in one pass. Mainnet EVM chains are paired with Tron mainnet;
 * testnet EVM chains are paired with Tron Shasta.
 *
 * All addresses (endpoints, libs, executor, DVNs) are read directly from
 * lzdeployconfigs.json — no lzDeployments.json lookup required.
 *
 * Usage:
 *   PRIVATE_KEY=... ALCHEMY_KEY=... \
 *     npx ts-node scripts/tron/configure-all-lz-routes.ts
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

// ─── Prover addresses (resolved + validated in main, no defaults) ───────────────

let EVM_LZ_PROVER      = ''
let TRON_LZ_PROVER     = ''
let TRON_LZ_PROVER_HEX = ''

function requireEnv(name: string, ...aliases: string[]): string {
  for (const key of [name, ...aliases]) {
    const v = process.env[key]
    if (v) return v
  }
  const names = [name, ...aliases].join(' / ')
  throw new Error(`${names} env var required`)
}

// ─── RPC helpers ──────────────────────────────────────────────────────────────

const ALCHEMY_SLUGS: Record<number, string> = {
  1:        'eth-mainnet',
  10:       'opt-mainnet',
  137:      'polygon-mainnet',
  999:      'hyperliquid-mainnet',
  9745:     'plasma-mainnet',
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

// ─── Config types ─────────────────────────────────────────────────────────────

interface EvmAddresses {
  lzEndpoint: string
  sendLib: string
  receiveLib: string
  executor: string
  dvns: Record<string, string>
}

interface TronAddresses {
  lzEndpoint: string
  sendLib: string
  receiveLib: string
  dvns: Record<string, string>
}

interface DvnConfig {
  required: string[]
  optional: string[]
  optionalThreshold: number
}

interface EvmChainConfig {
  chainKey: string
  chainName: string
  chainId: number
  lzEid: number
  addresses: EvmAddresses
  dvns: DvnConfig
}

interface TronChainConfig {
  chainKey: string
  chainName: string
  chainId: number
  lzEid: number
  addresses: TronAddresses
  dvns: DvnConfig
}

function loadDeployConfigs(): { mainnet: EvmChainConfig[]; testnet: EvmChainConfig[] } {
  const p = path.join(__dirname, 'lzdeployconfigs.json')
  return JSON.parse(fs.readFileSync(p, 'utf8'))
}

// ─── Config resolution ────────────────────────────────────────────────────────

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

function resolveDvnAddresses(names: string[], chainAddresses: Record<string, string>, chainName: string): string[] {
  return names.map(name => {
    const addr = chainAddresses[name]
    if (!addr) throw new Error(`DVN address for '${name}' missing on ${chainName}`)
    return addr
  })
}

function resolveConfig(evmCfg: EvmChainConfig, tronCfg: TronChainConfig): ResolvedLzConfig {
  const { required: requiredNames, optional: optionalNames, optionalThreshold } = evmCfg.dvns

  const evmRequiredDvns  = resolveDvnAddresses(requiredNames, evmCfg.addresses.dvns,  evmCfg.chainName)
  const evmOptionalDvns  = resolveDvnAddresses(optionalNames, evmCfg.addresses.dvns,  evmCfg.chainName)
  const tronRequiredDvns = resolveDvnAddresses(requiredNames, tronCfg.addresses.dvns, tronCfg.chainName)
  const tronOptionalDvns = resolveDvnAddresses(optionalNames, tronCfg.addresses.dvns, tronCfg.chainName)

  const dvnNames = [...requiredNames, ...optionalNames]
  const dvnSetup = optionalNames.length > 0
    ? `${requiredNames.length} required + ${optionalThreshold}-of-${optionalNames.length} optional`
    : `${requiredNames.length} required`

  return {
    evmEid:                evmCfg.lzEid,
    tronEid:               tronCfg.lzEid,
    evmEndpoint:           evmCfg.addresses.lzEndpoint,
    evmSendLib:            evmCfg.addresses.sendLib,
    evmRecvLib:            evmCfg.addresses.receiveLib,
    evmExecutor:           evmCfg.addresses.executor,
    evmRequiredDvns,
    evmOptionalDvns,
    evmOptionalThreshold:  optionalThreshold,
    tronEndpoint:          tronCfg.addresses.lzEndpoint,
    tronSendLib:           tronCfg.addresses.sendLib,
    tronRecvLib:           tronCfg.addresses.receiveLib,
    tronRequiredDvns,
    tronOptionalDvns,
    tronOptionalThreshold: optionalThreshold,
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
  const requiredDVNCount = sortReq.length === 0 ? 255 : sortReq.length
  return ethers.AbiCoder.defaultAbiCoder().encode(
    ['tuple(uint64 confirmations, uint8 requiredDVNCount, uint8 optionalDVNCount, uint8 optionalDVNThreshold, address[] requiredDVNs, address[] optionalDVNs)'],
    [[confirmations, requiredDVNCount, sortOpt.length, optionalThreshold, sortReq, sortOpt]],
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
  const tronGridKey = process.env.TRONGRID_API_KEY || ''
  const tw = new TronWeb({
    fullHost: rpcUrl,
    privateKey,
    ...(tronGridKey ? { headers: { 'TRON-PRO-API-KEY': tronGridKey } } : {}),
  })
  const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms))

  const tronEndpointB58 = tw.address.fromHex('41' + cfg.tronEndpoint.slice(2)) as string

  console.log(`\n=== Configuring Tron (EID ${cfg.tronEid}) → ${chainName} (EID ${cfg.evmEid}) ===`)
  console.log(`  Wallet:   ${tw.address.fromPrivateKey(privateKey)}`)
  console.log(`  OApp:     ${TRON_LZ_PROVER}`)
  console.log(`  Endpoint: ${tronEndpointB58}`)
  console.log(`  SendLib:  ${cfg.tronSendLib}`)
  console.log(`  RecvLib:  ${cfg.tronRecvLib}`)
  console.log(`  DVNs:     ${cfg.dvnNames.join(', ')} (${cfg.dvnSetup})`)

  const fire = async (label: string, funcSig: string, params: any[]): Promise<string> => {
    console.log(`  ${label}...`)
    const result = await tw.transactionBuilder.triggerSmartContract(
      tronEndpointB58, funcSig,
      { feeLimit: 500_000_000, callValue: 0 },
      params,
    )
    const signed = await tw.trx.sign(result.transaction)
    const resp   = await tw.trx.sendRawTransaction(signed)
    if (!resp.result) throw new Error(`Broadcast failed: ${JSON.stringify(resp)}`)
    return resp.txid
  }

  const fireSetConfig = async (label: string, lib: string, configParams: { eid: number; configType: number; config: string }[]): Promise<string> => {
    console.log(`  ${label}...`)
    const fullCalldata = TRON_ENDPOINT_IFACE.encodeFunctionData('setConfig', [
      TRON_LZ_PROVER_HEX,
      lib,
      configParams.map(p => [p.eid, p.configType, p.config]),
    ])
    const result = await tw.transactionBuilder.triggerSmartContract(
      tronEndpointB58,
      'setConfig(address,address,(uint32,uint32,bytes)[])',
      { feeLimit: 500_000_000, callValue: 0, rawParameter: fullCalldata.slice(10) },
      [],
    )
    const signed = await tw.trx.sign(result.transaction)
    const resp   = await tw.trx.sendRawTransaction(signed)
    if (!resp.result) throw new Error(`Broadcast failed: ${JSON.stringify(resp)}`)
    return resp.txid
  }

  const ALREADY_SET_SELECTORS = new Set([
    'd0ecb66b',
    'c4c52593',
  ])

  const confirm = async (txId: string, alreadySetOk = true): Promise<void> => {
    for (let i = 0; i < 60; i++) {
      await sleep(3000)
      const info: any = await tw.trx.getTransactionInfo(txId)
      if (info?.id) {
        if (info.receipt?.result !== 'SUCCESS') {
          if (alreadySetOk && ALREADY_SET_SELECTORS.has(info.contractResult?.[0])) {
            console.log(`    txId: ${txId} (already set — skipped)`)
            return
          }
          throw new Error(`Tx failed: ${JSON.stringify(info)}`)
        }
        console.log(`    txId: ${txId}`)
        return
      }
    }
    throw new Error(`Timed out waiting for ${txId}`)
  }

  console.log('\n  [Round 1/2] setSendLibrary + setReceiveLibrary')
  const [txId1, txId2] = await Promise.all([
    fire('[1/4] setSendLibrary', 'setSendLibrary(address,uint32,address)', [
      { type: 'address', value: TRON_LZ_PROVER },
      { type: 'uint32',  value: cfg.evmEid },
      { type: 'address', value: cfg.tronSendLib },
    ]),
    fire('[2/4] setReceiveLibrary', 'setReceiveLibrary(address,uint32,address,uint256)', [
      { type: 'address', value: TRON_LZ_PROVER },
      { type: 'uint32',  value: cfg.evmEid },
      { type: 'address', value: cfg.tronRecvLib },
      { type: 'uint256', value: 0 },
    ]),
  ])
  await Promise.all([confirm(txId1), confirm(txId2)])

  console.log('\n  [Round 2/2] setConfig ULN send + setConfig ULN recv')
  const [txId3, txId4] = await Promise.all([
    fireSetConfig('[3/4] setConfig ULN send', cfg.tronSendLib, [
      { eid: cfg.evmEid, configType: CONFIG_TYPE_ULN, config: encodeUlnConfig(2, cfg.tronRequiredDvns, cfg.tronOptionalDvns, cfg.tronOptionalThreshold) },
    ]),
    fireSetConfig('[4/4] setConfig ULN recv', cfg.tronRecvLib, [
      { eid: cfg.evmEid, configType: CONFIG_TYPE_ULN, config: encodeUlnConfig(2, cfg.tronRequiredDvns, cfg.tronOptionalDvns, cfg.tronOptionalThreshold) },
    ]),
  ])
  await Promise.all([confirm(txId3), confirm(txId4)])

  console.log(`\n  ✓ Tron configuration complete`)
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const evmOnly  = process.argv.includes('--evm-only')
  const tronOnly = process.argv.includes('--tron-only')
  if (evmOnly && tronOnly) throw new Error('Cannot pass both --evm-only and --tron-only')

  let pk = requireEnv('PRIVATE_KEY')
  if (pk.startsWith('0x')) pk = pk.slice(2)

  const alchemyKey = tronOnly ? '' : requireEnv('ALCHEMY_KEY', 'ALCHEMY_API_KEY')

  // Resolve + validate prover addresses (no defaults — throw if missing)
  if (!tronOnly) EVM_LZ_PROVER = requireEnv('EVM_LZ_PROVER')
  if (!evmOnly) {
    TRON_LZ_PROVER     = requireEnv('TRON_LZ_PROVER')
    TRON_LZ_PROVER_HEX = requireEnv('TRON_LZ_PROVER_HEX', 'TRON_LZ_PROVER_HEX20')
  }

  const { mainnet, testnet } = loadDeployConfigs()

  const tronMainnet = mainnet.find(c => c.chainKey === 'tron') as unknown as TronChainConfig
  const tronShasta  = testnet.find(c => c.chainKey === 'tron-shasta') as unknown as TronChainConfig
  if (!tronMainnet) throw new Error('tron entry missing from mainnet in lzdeployconfigs.json')
  if (!tronShasta)  throw new Error('tron-shasta entry missing from testnet in lzdeployconfigs.json')

  // Optional --chains filter: only configure the listed chainKeys
  const chainsIdx = process.argv.indexOf('--chains')
  const chainsVal = chainsIdx !== -1
    ? process.argv[chainsIdx + 1]
    : process.argv.find(a => a.startsWith('--chains='))?.split('=')[1]
  const chainFilter = chainsVal && !chainsVal.startsWith('--')
    ? new Set(chainsVal.split(',').map(s => s.trim().toLowerCase()))
    : null

  const mainnetEvmChains = mainnet.filter(c => c.chainKey !== 'tron')
  const testnetEvmChains = testnet.filter(c => c.chainKey !== 'tron-shasta')

  let routes: Array<{ evmCfg: EvmChainConfig; tronCfg: TronChainConfig }> = [
    ...mainnetEvmChains.map(evmCfg => ({ evmCfg, tronCfg: tronMainnet })),
    ...testnetEvmChains.map(evmCfg => ({ evmCfg, tronCfg: tronShasta })),
  ]

  if (chainFilter) {
    routes = routes.filter(r => chainFilter.has(r.evmCfg.chainKey.toLowerCase()))
    if (routes.length === 0) {
      throw new Error(`No routes matched --chains=${chainsVal}. Available: ${[...mainnetEvmChains, ...testnetEvmChains].map(c => c.chainKey).join(', ')}`)
    }
  }

  console.log(`Configuring ${routes.length} route(s):`)
  for (const { evmCfg, tronCfg } of routes) {
    console.log(`  ${evmCfg.chainName} (EID ${evmCfg.lzEid}) ↔ ${tronCfg.chainName} (EID ${tronCfg.lzEid})`)
  }

  for (const { evmCfg, tronCfg } of routes) {
    console.log(`\n${'─'.repeat(60)}`)
    console.log(`Route: ${evmCfg.chainName} ↔ ${tronCfg.chainName}`)
    console.log(`${'─'.repeat(60)}`)

    const cfg = resolveConfig(evmCfg, tronCfg)

    if (tronOnly) {
      await configureTron(pk, tronRpcUrl(tronCfg.chainId), cfg, evmCfg.chainName)
    } else if (evmOnly) {
      await configureEvm(pk, evmRpcUrl(evmCfg.chainId, alchemyKey), cfg, evmCfg.chainName)
    } else {
      await Promise.all([
        configureEvm(pk, evmRpcUrl(evmCfg.chainId, alchemyKey), cfg, evmCfg.chainName),
        configureTron(pk, tronRpcUrl(tronCfg.chainId), cfg, evmCfg.chainName),
      ])
    }
  }

  console.log('\n=== All routes configured ===')
  if (!tronOnly) console.log(`  EVM LZ Prover:  ${EVM_LZ_PROVER}`)
  if (!evmOnly)  console.log(`  Tron LZ Prover: ${TRON_LZ_PROVER}`)
}

main().catch(err => { console.error(err); process.exitCode = 1 })
