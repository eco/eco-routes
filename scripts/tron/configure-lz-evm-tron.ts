/**
 * configure-lz-evm-tron.ts
 *
 * Configures the LayerZero OApp settings for any EVM ↔ Tron route on both sides.
 *
 * Steps:
 *   EVM: setSendLibrary, setReceiveLibrary, setConfig(ULN send), setConfig(executor), setConfig(ULN recv)
 *   Tron: setSendLibrary, setReceiveLibrary, setConfig(ULN send), setConfig(ULN recv)
 *
 * Usage:
 *   PRIVATE_KEY=... \
 *   EVM_RPC_URL=https://polygon-rpc.com \
 *   EVM_EID=30109 \
 *   EVM_SEND_LIB=0x6c26c61a97006888ea9E4FA36584c7df57Cd9dA3 \
 *   EVM_RECV_LIB=0x1322871e4ab09Bc7f5717189434f97bBD9546e95 \
 *   EVM_EXECUTOR=0xCd3F213AD101472e1713C72B1697E727C803885b \
 *   EVM_DVN=0x23de2fe932d9043291f870324b74f820e11dc81a \
 *   EVM_CHAIN_NAME=Polygon \
 *     npx ts-node scripts/configure-lz-evm-tron.ts
 *
 * Optional prover overrides (default to prod addresses):
 *   EVM_LZ_PROVER      — EVM LZ Prover address (hex20)
 *   TRON_LZ_PROVER     — Tron LZ Prover address (base58)
 *   TRON_LZ_PROVER_HEX — Tron LZ Prover address (hex20)
 */

import { ethers } from 'ethers'
import { TronWeb } from 'tronweb'
import 'dotenv/config'

// ─── Shared constants ─────────────────────────────────────────────────────────

const EVM_LZ_PROVER      = process.env.EVM_LZ_PROVER      || '0xf64eaca0D1cF874ea34b8E73127f0Fe535c6be41'
const TRON_LZ_PROVER     = process.env.TRON_LZ_PROVER     || 'TYeFezmGQGEJU9JzykGebuNVvtmXQPTupz'
const TRON_LZ_PROVER_HEX = process.env.TRON_LZ_PROVER_HEX || '0xf8b5348d6e1e4c47de4abc2d9946963a7a37f2c8'
const TRON_EID           = parseInt(process.env.TRON_EID || '30420')

// Tron LZ contracts — default to mainnet, override via env for testnet
const TRON_ENDPOINT = process.env.TRON_ENDPOINT || '0x0Af59750D5dB5460E5d89E268C474d5F7407c061'
const TRON_SEND_LIB = process.env.TRON_SEND_LIB || '0xE369D146219380B24Bb5D9B9E08a5b9936F9E719'
const TRON_RECV_LIB = process.env.TRON_RECV_LIB || '0x612215D4dB0475a76dCAa36C7f9afD748c42ed2D'
const TRON_DVN      = process.env.TRON_DVN      || '0x8bc1d368036ee5e726d230beb685294be191a24e'

// LZ endpoint on EVM — default to mainnet, override via env for testnet
const EVM_ENDPOINT = process.env.EVM_ENDPOINT || '0x1a44076050125825900e736c501f859c50fE728c'

const CONFIG_TYPE_EXECUTOR = 1
const CONFIG_TYPE_ULN      = 2

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

function encodeExecutorConfig(maxMessageSize: number, executor: string): string {
  return ethers.AbiCoder.defaultAbiCoder().encode(
    ['tuple(uint32 maxMessageSize, address executorAddress)'],
    [[maxMessageSize, executor]],
  )
}

function encodeUlnConfig(confirmations: number, dvns: string[]): string {
  const sorted = [...dvns].sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()))
  return ethers.AbiCoder.defaultAbiCoder().encode(
    ['tuple(uint64 confirmations, uint8 requiredDVNCount, uint8 optionalDVNCount, uint8 optionalDVNThreshold, address[] requiredDVNs, address[] optionalDVNs)'],
    [[confirmations, sorted.length, 0, 0, sorted, []]],
  )
}

// ─── EVM config ───────────────────────────────────────────────────────────────

async function configureEvm(
  privateKey: string,
  rpcUrl: string,
  evmEid: number,
  evmSendLib: string,
  evmRecvLib: string,
  evmExecutor: string,
  evmDvn: string,
  chainName: string,
): Promise<void> {
  const provider = new ethers.JsonRpcProvider(rpcUrl)
  const wallet   = new ethers.Wallet('0x' + privateKey, provider)
  const endpoint = new ethers.Contract(EVM_ENDPOINT, ENDPOINT_ABI, wallet)

  console.log(`=== Configuring ${chainName} (EID ${evmEid}) → Tron (EID ${TRON_EID}) ===`)
  console.log(`  Wallet: ${wallet.address}`)
  console.log(`  OApp:   ${EVM_LZ_PROVER}`)

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

  await trySet('[1/5] setSendLibrary',    () => endpoint.setSendLibrary(EVM_LZ_PROVER, TRON_EID, evmSendLib))
  await trySet('[2/5] setReceiveLibrary', () => endpoint.setReceiveLibrary(EVM_LZ_PROVER, TRON_EID, evmRecvLib, 0))

  let tx: any
  console.log('  [3/5] setConfig ULN send...')
  tx = await endpoint.setConfig(EVM_LZ_PROVER, evmSendLib, [{ eid: TRON_EID, configType: CONFIG_TYPE_ULN, config: encodeUlnConfig(2, [evmDvn]) }])
  await tx.wait(); console.log(`    tx: ${tx.hash}`)

  console.log('  [4/5] setConfig Executor...')
  tx = await endpoint.setConfig(EVM_LZ_PROVER, evmSendLib, [{ eid: TRON_EID, configType: CONFIG_TYPE_EXECUTOR, config: encodeExecutorConfig(10000, evmExecutor) }])
  await tx.wait(); console.log(`    tx: ${tx.hash}`)

  console.log('  [5/5] setConfig ULN recv...')
  tx = await endpoint.setConfig(EVM_LZ_PROVER, evmRecvLib, [{ eid: TRON_EID, configType: CONFIG_TYPE_ULN, config: encodeUlnConfig(2, [evmDvn]) }])
  await tx.wait(); console.log(`    tx: ${tx.hash}`)

  console.log(`\n  ✓ ${chainName} configuration complete`)
}

// ─── Tron config ──────────────────────────────────────────────────────────────

async function configureTron(privateKey: string, rpcUrl: string, evmEid: number, chainName: string): Promise<void> {
  const tw = new TronWeb({ fullHost: rpcUrl, privateKey })
  const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms))

  const tronEndpointB58 = tw.address.fromHex('41' + TRON_ENDPOINT.slice(2)) as string

  console.log(`\n=== Configuring Tron (EID ${TRON_EID}) → ${chainName} (EID ${evmEid}) ===`)
  console.log(`  Wallet: ${tw.address.fromPrivateKey(privateKey)}`)
  console.log(`  OApp:   ${TRON_LZ_PROVER}`)

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
    { type: 'uint32',  value: evmEid },
    { type: 'address', value: TRON_SEND_LIB },
  ])

  await sendAndWait('[2/4] setReceiveLibrary', 'setReceiveLibrary(address,uint32,address,uint256)', [
    { type: 'address', value: TRON_LZ_PROVER },
    { type: 'uint32',  value: evmEid },
    { type: 'address', value: TRON_RECV_LIB },
    { type: 'uint256', value: 0 },
  ])

  await sendSetConfig('[3/4] setConfig ULN send', TRON_SEND_LIB, [
    { eid: evmEid, configType: CONFIG_TYPE_ULN, config: encodeUlnConfig(2, [TRON_DVN]) },
  ])

  await sendSetConfig('[4/4] setConfig ULN recv', TRON_RECV_LIB, [
    { eid: evmEid, configType: CONFIG_TYPE_ULN, config: encodeUlnConfig(2, [TRON_DVN]) },
  ])

  console.log(`\n  ✓ Tron configuration complete`)
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  let pk = process.env.PRIVATE_KEY || ''
  if (!pk) throw new Error('PRIVATE_KEY required')
  if (pk.startsWith('0x')) pk = pk.slice(2)

  const evmRpc      = process.env.EVM_RPC_URL || ''; if (!evmRpc) throw new Error('EVM_RPC_URL required')
  const evmEidStr   = process.env.EVM_EID || '';     if (!evmEidStr) throw new Error('EVM_EID required')
  const evmSendLib  = process.env.EVM_SEND_LIB || ''; if (!evmSendLib) throw new Error('EVM_SEND_LIB required')
  const evmRecvLib  = process.env.EVM_RECV_LIB || ''; if (!evmRecvLib) throw new Error('EVM_RECV_LIB required')
  const evmExecutor = process.env.EVM_EXECUTOR || ''; if (!evmExecutor) throw new Error('EVM_EXECUTOR required')
  const evmDvn      = process.env.EVM_DVN || '';      if (!evmDvn) throw new Error('EVM_DVN required')
  const tronRpc     = process.env.TRON_RPC_URL || 'https://api.trongrid.io'
  const chainName   = process.env.EVM_CHAIN_NAME || 'EVM'

  const evmEid = parseInt(evmEidStr)

  await configureEvm(pk, evmRpc, evmEid, evmSendLib, evmRecvLib, evmExecutor, evmDvn, chainName)
  await configureTron(pk, tronRpc, evmEid, chainName)

  console.log('\n=== All done ===')
  console.log(`  EVM LZ Prover:  ${EVM_LZ_PROVER}`)
  console.log(`  Tron LZ Prover: ${TRON_LZ_PROVER}`)
}

main().catch(err => { console.error(err); process.exitCode = 1 })
