/**
 * deploy-tron-layerzero-prover.ts — deploys the Tron LayerZeroProver (PAR-503).
 *
 * Tron only: the EVM provers are deployed by eco-routes-deployer (`pnpm start deploy
 * --contract layerzeroprover`), and every pathway, Tron included, is configured, verified
 * and revoked with its `lz` command. This script deploys the Tron prover through the Tron
 * CREATE2 factory with the v2.12 constructor:
 *
 *   (endpoint, delegate, portal, provers = [EVM prover], minGasLimit = 200000,
 *    domainConfig = every EVM chain of config/layerzero.json, eid -> chainId)
 *
 * Deploy Tron FIRST: its whitelist needs the EVM prover's predicted CREATE3 address, and the
 * EVM provers need this Tron address in config/layerzero.json `crossVmProvers`.
 *
 * Usage (run by the operator holding the eco-deployer key):
 *   PRIVATE_KEY=... npx ts-node scripts/tron/deploy-tron-layerzero-prover.ts \
 *     --policy ../eco-routes-deployer/config/layerzero.json \
 *     --evm-prover 0xEc00FE5F9625328757A0648934EAbe9A5685a541 \
 *     --portal <Tron Portal, 0x hex or T... base58> --salt <bytes32>
 *
 *   # Predict only, no key needed:
 *   npx ts-node scripts/tron/deploy-tron-layerzero-prover.ts ... --dry-run --delegate <0x hex>
 *
 * Env: PRIVATE_KEY (not needed with --dry-run), TRON_RPC_URL (Tron full-node HTTP API,
 * default https://api.trongrid.io), TRON_CREATE2_FACTORY (default the mainnet factory).
 */
import * as fs from 'fs'
import * as path from 'path'
import { ethers } from 'ethers'
import { TronWeb } from 'tronweb'
import {
  buildTronLayerZeroProverInitCode,
  predictTronCreate2Address,
  tronDomainConfig,
} from './layerzero-tron-prover'

const MAINNET_CREATE2_FACTORY = 'TRoohco2jc4Cmfbh92CWcfNtdBmBDj3fzy'
const DEPLOYED_TOPIC = ethers.id('Deployed(address,bytes32)').slice(2)
const DEPLOY_FEE_LIMIT_SUN = 5_000_000_000

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`)
  return i === -1 ? undefined : process.argv[i + 1]
}

function required(name: string): string {
  const value = arg(name)
  if (!value) throw new Error(`--${name} is required`)
  return value
}

/** 0x-hex20 from 0x-hex, 41-hex or base58. */
function toHex20(tronWeb: TronWeb, address: string): string {
  if (address.startsWith('0x')) return address.toLowerCase()
  if (/^41[0-9a-fA-F]{40}$/.test(address))
    return ('0x' + address.slice(2)).toLowerCase()
  return (
    '0x' + (tronWeb.address.toHex(address) as string).slice(2)
  ).toLowerCase()
}

const toBase58 = (hex20: string) =>
  TronWeb.address.fromHex('41' + hex20.slice(2)) as string

async function main(): Promise<void> {
  const dryRun = process.argv.includes('--dry-run')
  const policy = JSON.parse(
    fs.readFileSync(path.resolve(required('policy')), 'utf8'),
  )
  const salt = ethers.zeroPadValue(required('salt'), 32)
  const fullHost = process.env.TRON_RPC_URL ?? 'https://api.trongrid.io'

  const privateKey = (process.env.PRIVATE_KEY ?? '').replace(/^0x/, '')
  if (!privateKey && !dryRun)
    throw new Error('PRIVATE_KEY is required (or use --dry-run)')
  const tronWeb = new TronWeb(
    privateKey ? { fullHost, privateKey } : { fullHost },
  )

  const delegate = privateKey
    ? toHex20(tronWeb, tronWeb.defaultAddress.base58 as string)
    : toHex20(tronWeb, required('delegate'))
  const factory = process.env.TRON_CREATE2_FACTORY ?? MAINNET_CREATE2_FACTORY
  const factoryHex20 = toHex20(tronWeb, factory)

  const artifactPath = path.join(
    __dirname,
    '../../out/LayerZeroProver.sol/LayerZeroProver.json',
  )
  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'))
  const { initCode, endpoint, whitelist } = buildTronLayerZeroProverInitCode(
    artifact.bytecode.object ?? artifact.bytecode,
    policy,
    {
      evmProver: required('evm-prover'),
      portal: toHex20(tronWeb, required('portal')),
      delegate,
    },
  )
  const domains = tronDomainConfig(policy)
  const predicted = predictTronCreate2Address(factoryHex20, salt, initCode)

  console.log('Tron LayerZeroProver')
  console.log(`  endpoint:    ${endpoint} (${toBase58(endpoint)})`)
  console.log(`  delegate:    ${delegate} (${toBase58(delegate)})`)
  console.log(`  portal:      ${toHex20(tronWeb, required('portal'))}`)
  console.log(`  whitelist:   ${whitelist.join(', ')}`)
  console.log(
    `  domain map (${domains.length}): ${domains.map((d) => `${d.domain}->${d.chainId}`).join(', ')}`,
  )
  console.log(`  factory:     ${factory}`)
  console.log(`  salt:        ${salt}`)
  console.log(`  predicted:   ${predicted} (${toBase58(predicted)})`)

  const existing = await tronWeb.trx
    .getContract(toBase58(predicted))
    .catch(() => undefined)
  if ((existing as { bytecode?: string } | undefined)?.bytecode) {
    console.log(
      '\nA contract already exists at the predicted address; verifying it instead.',
    )
    await verify(tronWeb, predicted, { endpoint, delegate, whitelist, domains })
    return
  }
  if (dryRun) {
    console.log('\n[dry run] nothing sent.')
    return
  }

  const built = await tronWeb.transactionBuilder.triggerSmartContract(
    toBase58(factoryHex20),
    'deploy(bytes,bytes32)',
    { feeLimit: DEPLOY_FEE_LIMIT_SUN, callValue: 0 },
    [
      { type: 'bytes', value: initCode },
      { type: 'bytes32', value: salt },
    ],
  )
  const signed = await tronWeb.trx.sign(built.transaction)
  const sent = await tronWeb.trx.sendRawTransaction(signed)
  if (!sent.result)
    throw new Error(`Broadcast failed: ${String(sent.code ?? '')}`)
  console.log(`\n  tx: ${sent.txid}`)

  let deployed: string | undefined
  for (let i = 0; i < 60 && !deployed; i++) {
    await new Promise((resolve) => setTimeout(resolve, 3000))
    const info = (await tronWeb.trx.getTransactionInfo(sent.txid)) as {
      id?: string
      receipt?: { result?: string }
      log?: { topics?: string[] }[]
    }
    if (!info?.id) continue
    if (info.receipt?.result !== 'SUCCESS') {
      throw new Error(`Deploy reverted: ${info.receipt?.result}`)
    }
    const log = (info.log ?? []).find((l) => l.topics?.[0] === DEPLOYED_TOPIC)
    if (!log) throw new Error('No Deployed event in the receipt')
    deployed = '0x' + log.topics![1].slice(-40).toLowerCase()
  }
  if (!deployed) throw new Error(`Timed out waiting for ${sent.txid}`)
  if (deployed !== predicted) {
    throw new Error(`Deployed at ${deployed}, but predicted ${predicted}`)
  }
  await verify(tronWeb, deployed, { endpoint, delegate, whitelist, domains })

  console.log(
    '\nNext: add this address to eco-routes-deployer config/layerzero.json crossVmProvers:',
  )
  console.log(`  "${deployed}"`)
}

/** Reads the deployed prover back and fails on any mismatch. */
async function verify(
  tronWeb: TronWeb,
  prover: string,
  expected: {
    endpoint: string
    delegate: string
    whitelist: string[]
    domains: { domain: bigint; chainId: bigint }[]
  },
): Promise<void> {
  const call = async (
    target: string,
    signature: string,
    types: string[],
    values: unknown[],
  ) => {
    const coder = ethers.AbiCoder.defaultAbiCoder()
    const res = await tronWeb.transactionBuilder.triggerConstantContract(
      toBase58(target),
      signature,
      { rawParameter: coder.encode(types, values).slice(2) },
      [],
    )
    if (res.result?.result !== true)
      throw new Error(`${signature} failed on ${target}`)
    return '0x' + (res.constant_result?.[0] ?? '')
  }
  const coder = ethers.AbiCoder.defaultAbiCoder()
  const problems: string[] = []

  const [whitelist] = coder.decode(
    ['bytes32[]'],
    await call(prover, 'getWhitelist()', [], []),
  )
  const got = (whitelist as string[]).map((w) => w.toLowerCase())
  if (
    JSON.stringify(got) !==
    JSON.stringify(expected.whitelist.map((w) => w.toLowerCase()))
  ) {
    problems.push(`whitelist is [${got.join(', ')}]`)
  }
  for (const { domain, chainId } of expected.domains) {
    const [mapped] = coder.decode(
      ['uint64'],
      await call(prover, 'chainIdByDomain(uint64)', ['uint64'], [domain]),
    )
    if (mapped !== chainId)
      problems.push(
        `chainIdByDomain(${domain}) is ${mapped}, expected ${chainId}`,
      )
  }
  const [endpoint] = coder.decode(
    ['address'],
    await call(prover, 'ENDPOINT()', [], []),
  )
  if (endpoint.toLowerCase() !== expected.endpoint)
    problems.push(`ENDPOINT() is ${endpoint}`)
  const [delegate] = coder.decode(
    ['address'],
    await call(expected.endpoint, 'delegates(address)', ['address'], [prover]),
  )
  if (delegate.toLowerCase() !== expected.delegate) {
    problems.push(
      `endpoint delegate is ${delegate}, expected ${expected.delegate}`,
    )
  }

  if (problems.length > 0) {
    throw new Error(
      `Tron LayerZeroProver ${prover} does not match:\n  - ${problems.join('\n  - ')}`,
    )
  }
  console.log(
    `  ✓ verified ${prover}: whitelist, ${expected.domains.length} domains, endpoint, delegate`,
  )
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
})
