/**
 * deploy-tron-next-gen-prover.ts — deploys one of the next generation's Tron provers against
 * the kept PortalTron (TDYD42VmbScmqYkqG97aLgRN74Dqq9Fuva), through the same Tron CREATE2
 * factory as deploy-tron-layerzero-prover.ts, so the address is known before broadcast:
 *
 *   --contract hyper       HyperProver(mailbox, PortalTron, [pad(EVM HyperProver)],
 *                          identity domain map of the 12 EVM lanes)
 *   --contract polymer     PolymerProver(PortalTron, CrossL2ProverV2, 2048, 2, 1399811149,
 *                          [pad(EVM PolymerProver)])
 *   --contract aggregator  AggregatorProver([pad(hyper), pad(polymer), pad(layerzero)])
 *
 * The fixed values live in next-gen-tron-provers.ts (NEXT_GEN). Nothing Solana is
 * whitelisted: Tron↔Solana is intentionally closed (PolymerProver still needs the Solana
 * chain ids because its constructor rejects zero).
 *
 * Dry run is the default: it prints the decoded and ABI-encoded constructor arguments, the
 * predicted address, the deployer's TRX and energy, and an energy estimate from simulating
 * the factory call (which also proves the predicted address). Nothing is signed. If a
 * contract already exists at the predicted address, the run reads it back instead, so the
 * same command is the post-deploy check.
 *
 * Usage (the operator holding the eco-deployer key):
 *   npx ts-node scripts/tron/deploy-tron-next-gen-prover.ts --contract hyper --salt <bytes32>
 *   npx ts-node scripts/tron/deploy-tron-next-gen-prover.ts --contract polymer --salt <bytes32>
 *   npx ts-node scripts/tron/deploy-tron-next-gen-prover.ts --contract aggregator --salt <bytes32> \
 *     --hyper <T…|0x…> --polymer <T…|0x…> --layerzero <T…|0x…>
 *   ... add --execute to broadcast (needs PRIVATE_KEY and enough energy; see --allow-trx-burn)
 *
 * Flags: --from <T…> estimates energy for that deployer when no key is set;
 *        --allow-trx-burn lets --execute proceed when rented energy is below the estimate
 *        (the shortfall is burned as TRX, up to the fee limit).
 * Env: PRIVATE_KEY (only with --execute; read, never printed), TRON_RPC_URL (Tron full-node
 * HTTP API, default https://api.trongrid.io), TRON_CREATE2_FACTORY (default the mainnet
 * factory), TRON_PRO_API_KEY (optional TronGrid header).
 */
import * as fs from 'fs'
import * as path from 'path'
import { ethers } from 'ethers'
import { TronWeb } from 'tronweb'
import { predictTronCreate2Address } from './layerzero-tron-prover'
import {
  AGGREGATOR_MEMBER_PROOF_TYPES,
  NEXT_GEN,
  ReadbackCheck,
  TRON_CHAIN_ID,
  aggregatorProverConstructorArgs,
  aggregatorProverReadback,
  buildInitCode,
  contractHasCode,
  hyperProverReadback,
  nextGenHyperProverArgs,
  nextGenPolymerProverArgs,
  parseTronAddress,
  polymerProverReadback,
  readbackMatches,
  requireLiveMembers,
  toTronBase58,
} from './next-gen-tron-provers'

const MAINNET_CREATE2_FACTORY = 'TRoohco2jc4Cmfbh92CWcfNtdBmBDj3fzy'
const DEPLOYED_TOPIC = ethers.id('Deployed(address,bytes32)').slice(2)
const DEPLOY_FEE_LIMIT_SUN = 5_000_000_000
/** Headroom over the simulated energy before --execute is allowed without --allow-trx-burn. */
const ENERGY_MARGIN = 1.1
const coder = ethers.AbiCoder.defaultAbiCoder()

type ContractKind = 'hyper' | 'polymer' | 'aggregator'
const ARTIFACTS: Record<ContractKind, string> = {
  hyper: 'HyperProver',
  polymer: 'PolymerProver',
  aggregator: 'AggregatorProver',
}

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`)
  return i === -1 ? undefined : process.argv[i + 1]
}

function required(name: string): string {
  const value = arg(name)
  if (!value || value.startsWith('--')) throw new Error(`--${name} is required`)
  return value
}

const fmt = (hex20: string) => `${toTronBase58(hex20)} (${hex20})`

/** One-line rendering of a constructor value; a 20-byte address also shows its base58. */
function describe(value: unknown): string {
  if (typeof value === 'string' && /^0x[0-9a-f]{40}$/.test(value))
    return fmt(value)
  if (Array.isArray(value)) {
    return `[${value
      .map((v) =>
        v && typeof v === 'object' && 'domain' in v
          ? `${(v as { domain: bigint }).domain}->${(v as { chainId: bigint }).chainId}`
          : describe(v),
      )
      .join(', ')}] (${value.length})`
  }
  return String(value)
}

function stringify(value: unknown): string {
  return JSON.stringify(
    value,
    (_k, v) => (typeof v === 'bigint' ? v.toString() : v),
    2,
  )
}

/** The handful of TronWeb reads this script needs. */
class TronClient {
  /**
   * @param caller owner_address for view calls and simulations (the deployer, or any
   *        address when none is known: views do not depend on it)
   */
  constructor(
    readonly tronWeb: TronWeb,
    readonly caller: string,
  ) {}

  async hasCode(hex20: string): Promise<boolean> {
    const contract = await this.tronWeb.trx
      .getContract(toTronBase58(hex20))
      .catch(() => undefined)
    return contractHasCode(
      contract as { bytecode?: string; code_hash?: string } | undefined,
    )
  }

  async requireCode(hex20: string, label: string): Promise<void> {
    if (!(await this.hasCode(hex20))) {
      throw new Error(`${label} ${fmt(hex20)} has no code on Tron`)
    }
    console.log(`  ✓ ${label} ${fmt(hex20)} holds code`)
  }

  /** A view call; returns the 0x-prefixed result. */
  async call(
    target: string,
    signature: string,
    types: string[] = [],
    values: unknown[] = [],
  ): Promise<string> {
    const res = await this.tronWeb.transactionBuilder.triggerConstantContract(
      toTronBase58(target),
      signature,
      { rawParameter: coder.encode(types, values).slice(2) },
      [],
      this.caller,
    )
    if (res.result?.result !== true) {
      throw new Error(`${signature} failed on ${fmt(target)}`)
    }
    return '0x' + (res.constant_result?.[0] ?? '')
  }
}

interface Plan {
  name: string
  /** Constructor parameter names, in order, for the dry-run printout. */
  params: string[]
  values: unknown[]
  encoded: string
  /** Read-only checks before anything is simulated or sent. */
  preflight: (tron: TronClient) => Promise<void>
  readback: (self: string) => ReadbackCheck[]
}

function plan(kind: ContractKind): Plan {
  if (kind === 'hyper') {
    const args = nextGenHyperProverArgs()
    return {
      name: 'HyperProver',
      params: ['mailbox', 'portal', 'provers', 'domainConfig'],
      values: args.values,
      encoded: args.encoded,
      preflight: async (tron) => {
        await tron.requireCode(NEXT_GEN.portalTron, 'PortalTron')
        await tron.requireCode(NEXT_GEN.tronMailbox, 'Mailbox')
        const [domain] = coder.decode(
          ['uint32'],
          await tron.call(NEXT_GEN.tronMailbox, 'localDomain()'),
        )
        if (BigInt(domain) !== TRON_CHAIN_ID) {
          throw new Error(
            `Mailbox localDomain() is ${domain}, expected ${TRON_CHAIN_ID}`,
          )
        }
        console.log(`  ✓ Mailbox localDomain() = ${domain}`)
      },
      readback: (self) => hyperProverReadback(self, args),
    }
  }
  if (kind === 'polymer') {
    const args = nextGenPolymerProverArgs()
    return {
      name: 'PolymerProver',
      params: [
        '_portal',
        '_crossL2ProverV2',
        '_maxLogDataSize',
        '_solanaPolymerChainId',
        '_solanaChainId',
        '_proverAddresses',
      ],
      values: args.values,
      encoded: args.encoded,
      preflight: async (tron) => {
        await tron.requireCode(NEXT_GEN.portalTron, 'PortalTron')
        await tron.requireCode(NEXT_GEN.tronCrossL2ProverV2, 'CrossL2ProverV2')
      },
      readback: (self) => polymerProverReadback(self, args),
    }
  }
  const args = aggregatorProverConstructorArgs([
    required('hyper'),
    required('polymer'),
    required('layerzero'),
  ])
  return {
    name: 'AggregatorProver',
    params: ['members'],
    values: args.values,
    encoded: args.encoded,
    preflight: async (tron) => {
      await requireLiveMembers(
        args.members,
        {
          hasCode: (m) => tron.hasCode(m),
          portal: async (m) =>
            coder.decode(['address'], await tron.call(m, 'PORTAL()'))[0],
          proofType: async (m) =>
            coder.decode(['string'], await tron.call(m, 'getProofType()'))[0],
        },
        {
          portal: NEXT_GEN.portalTron,
          proofTypes: AGGREGATOR_MEMBER_PROOF_TYPES,
        },
      )
      console.log(
        `  ✓ members hold code, PORTAL() = PortalTron, proof types ${AGGREGATOR_MEMBER_PROOF_TYPES.join(' > ')}`,
      )
    },
    readback: () => aggregatorProverReadback(args),
  }
}

async function main(): Promise<void> {
  const execute = process.argv.includes('--execute')
  const kind = required('contract') as ContractKind
  if (!(kind in ARTIFACTS)) {
    throw new Error('--contract must be hyper, polymer or aggregator')
  }
  const salt = ethers.zeroPadValue(required('salt'), 32)
  const fullHost = process.env.TRON_RPC_URL ?? 'https://api.trongrid.io'
  const privateKey = (process.env.PRIVATE_KEY ?? '').replace(/^0x/, '')
  if (execute && !privateKey) {
    throw new Error(
      'PRIVATE_KEY is required with --execute (omit --execute for a dry run)',
    )
  }
  const headers = process.env.TRON_PRO_API_KEY
    ? { 'TRON-PRO-API-KEY': process.env.TRON_PRO_API_KEY }
    : undefined
  const tronWeb = new TronWeb(
    privateKey ? { fullHost, headers, privateKey } : { fullHost, headers },
  )
  const factory = parseTronAddress(
    process.env.TRON_CREATE2_FACTORY ?? MAINNET_CREATE2_FACTORY,
    'TRON_CREATE2_FACTORY',
  )
  const deployer = privateKey
    ? (tronWeb.defaultAddress.base58 as string)
    : arg('from')
      ? toTronBase58(parseTronAddress(required('from'), '--from'))
      : undefined
  const tron = new TronClient(tronWeb, deployer ?? toTronBase58(factory))
  const p = plan(kind)
  const artifactPath = path.join(
    __dirname,
    `../../out/${ARTIFACTS[kind]}.sol/${ARTIFACTS[kind]}.json`,
  )
  if (!fs.existsSync(artifactPath)) {
    throw new Error(`${artifactPath} not found; run \`forge build\` first`)
  }
  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'))
  // Cross-check against the compiled ABI: the encoding must be the artifact's own.
  const fromAbi = new ethers.Interface(artifact.abi).encodeDeploy(p.values)
  if (fromAbi !== p.encoded) {
    throw new Error(
      `${p.name} constructor encoding disagrees with ${artifactPath}`,
    )
  }
  const initCode = buildInitCode(
    artifact.bytecode.object ?? artifact.bytecode,
    p.encoded,
  )
  const predicted = predictTronCreate2Address(factory, salt, initCode)

  console.log(`Tron ${p.name} (${execute ? 'EXECUTE' : 'dry run'})`)
  console.log('  constructor args (decoded):')
  p.params.forEach((name, i) =>
    console.log(`    ${name}: ${describe(p.values[i])}`),
  )
  console.log(`  constructor args (ABI-encoded): ${p.encoded}`)
  console.log(
    `  initCode: ${(initCode.length - 2) / 2} bytes, keccak256 ${ethers.keccak256(initCode)}`,
  )
  console.log(`  factory:   ${fmt(factory)}`)
  console.log(`  salt:      ${salt}`)
  console.log(`  predicted: ${fmt(predicted)}`)

  console.log('\nPreflight (read-only)')
  await tron.requireCode(factory, 'CREATE2 factory')
  await p.preflight(tron)

  if (await tron.hasCode(predicted)) {
    console.log(
      '\nA contract already exists at the predicted address; reading it back instead.',
    )
    await readback(tron, predicted, p.readback(predicted))
    printAddresses(p.name, predicted)
    return
  }

  let energyAvailable = 0
  if (deployer) {
    const balance = await tronWeb.trx.getBalance(deployer)
    const res = (await tronWeb.trx.getAccountResources(deployer)) as {
      EnergyLimit?: number
      EnergyUsed?: number
    }
    energyAvailable = (res.EnergyLimit ?? 0) - (res.EnergyUsed ?? 0)
    console.log(
      `\nDeployer ${deployer}: ${balance / 1e6} TRX, energy available ${energyAvailable}`,
    )
  } else {
    console.log(
      '\nDeployer unknown (no PRIVATE_KEY, no --from): simulating with the factory as caller.',
    )
  }

  // Simulate factory.deploy: the energy estimate, and the address the factory would return.
  const sim = (await tronWeb.transactionBuilder.triggerConstantContract(
    toTronBase58(factory),
    'deploy(bytes,bytes32)',
    {
      rawParameter: coder
        .encode(['bytes', 'bytes32'], [initCode, salt])
        .slice(2),
    },
    [],
    tron.caller,
  )) as {
    result?: { result?: boolean; message?: string }
    energy_used?: number
    constant_result?: string[]
  }
  if (sim.result?.result !== true) {
    const why = sim.result?.message
      ? Buffer.from(sim.result.message, 'hex').toString()
      : ''
    throw new Error(`Simulated deploy failed ${why}`)
  }
  const [simulated] = coder.decode(['address'], '0x' + sim.constant_result![0])
  if (simulated.toLowerCase() !== predicted) {
    throw new Error(
      `Simulation deploys at ${simulated}, but predicted ${predicted}`,
    )
  }
  const energy = sim.energy_used ?? 0
  // Informational only: some RPC providers refuse getchainparameters.
  const params = (await tronWeb.trx.getChainParameters().catch(() => [])) as {
    key: string
    value?: number
  }[]
  const energyFee = params.find((x) => x.key === 'getEnergyFee')?.value
  const burn = energyFee
    ? ` (~${(energy * energyFee) / 1e6} TRX if burned at ${energyFee} sun/energy)`
    : ''
  console.log(
    `  ✓ simulated deploy lands on the predicted address; energy ${energy}${burn}`,
  )
  const needed = Math.ceil(energy * ENERGY_MARGIN)
  console.log(
    `  energy to rent (estimate +10%): ${needed} → TARGET_ENERGY=${needed} for rent-energy-mainnet.ts`,
  )

  if (!execute) {
    console.log(
      '\n[dry run] nothing signed or sent. Add --execute to broadcast.',
    )
    return
  }
  if (energyAvailable < needed && !process.argv.includes('--allow-trx-burn')) {
    throw new Error(
      `Deployer has ${energyAvailable} energy, needs ~${needed}. Rent it first (rent-energy-mainnet.ts), or pass --allow-trx-burn.`,
    )
  }

  // The exact calldata the simulation ran, so the broadcast cannot diverge from it.
  const built = await tronWeb.transactionBuilder.triggerSmartContract(
    toTronBase58(factory),
    'deploy(bytes,bytes32)',
    {
      feeLimit: DEPLOY_FEE_LIMIT_SUN,
      callValue: 0,
      rawParameter: coder
        .encode(['bytes', 'bytes32'], [initCode, salt])
        .slice(2),
    },
    [],
    tron.caller,
  )
  if (!built.result?.result) {
    throw new Error('Building the deploy transaction failed')
  }
  const signed = await tronWeb.trx.sign(built.transaction)
  const sent = await tronWeb.trx.sendRawTransaction(signed)
  if (!sent.result) {
    throw new Error(`Broadcast failed: ${String(sent.code ?? '')}`)
  }
  console.log(`\n  tx: ${sent.txid}`)

  let deployed: string | undefined
  for (let i = 0; i < 60 && !deployed; i++) {
    await new Promise((resolve) => setTimeout(resolve, 3000))
    const info = (await tronWeb.trx.getTransactionInfo(sent.txid)) as {
      id?: string
      receipt?: { result?: string; energy_usage_total?: number }
      fee?: number
      log?: { topics?: string[] }[]
    }
    if (!info?.id) continue
    if (info.receipt?.result !== 'SUCCESS') {
      throw new Error(`Deploy reverted: ${info.receipt?.result}`)
    }
    const log = (info.log ?? []).find((l) => l.topics?.[0] === DEPLOYED_TOPIC)
    if (!log) throw new Error('No Deployed event in the receipt')
    deployed = '0x' + log.topics![1].slice(-40).toLowerCase()
    console.log(
      `  energy used ${info.receipt?.energy_usage_total}, fee ${(info.fee ?? 0) / 1e6} TRX`,
    )
  }
  if (!deployed) throw new Error(`Timed out waiting for ${sent.txid}`)
  if (deployed !== predicted) {
    throw new Error(`Deployed at ${deployed}, but predicted ${predicted}`)
  }
  await readback(tron, deployed, p.readback(deployed))
  printAddresses(p.name, deployed)
}

/** Runs every probe, prints a pass/fail table and throws if anything failed. */
async function readback(
  tron: TronClient,
  self: string,
  checks: ReadbackCheck[],
): Promise<void> {
  const rows: { status: string; label: string; detail: string }[] = []
  for (const check of checks) {
    let actual: unknown
    try {
      const raw = await tron.call(
        self,
        check.signature,
        check.argTypes,
        check.args,
      )
      actual = coder.decode([check.returnType], raw)[0]
    } catch (error) {
      rows.push({
        status: 'FAIL',
        label: check.label,
        detail: error instanceof Error ? error.message : String(error),
      })
      continue
    }
    const ok = readbackMatches(actual, check.expected)
    rows.push({
      status: ok ? 'PASS' : 'FAIL',
      label: check.label,
      detail: ok
        ? stringify(check.expected).replace(/\s+/g, ' ')
        : `got ${stringify(actual).replace(/\s+/g, ' ')}, expected ${stringify(check.expected).replace(/\s+/g, ' ')}`,
    })
  }
  const width = Math.max(...rows.map((r) => r.label.length))
  console.log(`\nRead-back of ${fmt(self)}`)
  for (const r of rows) {
    console.log(`  ${r.status}  ${r.label.padEnd(width)}  ${r.detail}`)
  }
  const failed = rows.filter((r) => r.status === 'FAIL').length
  if (failed > 0)
    throw new Error(`${failed} of ${rows.length} read-back checks failed`)
  console.log(`  all ${rows.length} checks passed`)
}

function printAddresses(name: string, hex20: string): void {
  console.log(`\n${name} on Tron:`)
  console.log(`  base58: ${toTronBase58(hex20)}`)
  console.log(`  hex:    ${hex20}`)
  if (name === 'HyperProver') {
    console.log(
      '  → eco-routes-deployer config/hyperprover.json tron.prover, and the Tron aggregator --hyper',
    )
  } else if (name === 'PolymerProver') {
    console.log(
      '  → eco-routes-deployer config/polymer.json tron.prover, and the Tron aggregator --polymer',
    )
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
})
