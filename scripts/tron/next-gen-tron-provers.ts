/**
 * Pure helpers for deploying the next generation's Tron provers against the kept PortalTron:
 * HyperProver, the 6-argument (Solana-capable) PolymerProver and the AggregatorProver. The
 * Tron LayerZeroProver has its own builder (layerzero-tron-prover.ts).
 *
 * Every constructor argument here is immutable in the deployed contract (no setters), so the
 * builders refuse anything that would bake in a wrong peer: a whitelist entry that is not a
 * left-padded 20-byte address (which is how a 32-byte Solana program ID or PDA would show
 * up), a Solana or Tron entry in the Hyperlane domain map, a bad base58 checksum, a codeless
 * aggregator member. Tron↔Solana is intentionally closed: nothing Solana is whitelisted.
 */
import { ethers } from 'ethers'

/** Tron mainnet chain id; also its Hyperlane domain (Mailbox.localDomain()). */
export const TRON_CHAIN_ID = 728126428n
/** Eco's Solana mainnet chain id; also Solana's Hyperlane domain. */
export const SOLANA_CHAIN_ID = 1399811149n
/** Polymer's identifier for Solana (confirmed on mainnet 2026-09-24). */
export const SOLANA_POLYMER_CHAIN_ID = 2n
/** PolymerProver `maxLogDataSize`, as Deploy.s.sol and the deployer pass it. */
export const POLYMER_MAX_LOG_DATA_SIZE = 2048n
/** AggregatorProver.MAX_MEMBERS. */
export const AGGREGATOR_MAX_MEMBERS = 8
/** Whitelist.MAX_WHITELIST_SIZE. */
export const MAX_WHITELIST_SIZE = 20

/**
 * The next generation's fixed inputs. Each was checked on 2026-10-13: the Mailbox's
 * localDomain() is 728126428, PortalTron and CrossL2ProverV2 hold code on Tron mainnet, and
 * the EVM provers are the CREATE3 addresses in eco-routes-deployer config/salts.json.
 */
export const NEXT_GEN = {
  /** Kept PortalTron TDYD42VmbScmqYkqG97aLgRN74Dqq9Fuva. */
  portalTron: '0x27262594c6088865ac3e7ac20f401af3bd379b1b',
  /** Tron Hyperlane Mailbox (TKwSnSwg8ZiDs379kisot8KwWXVV1FcDgT). */
  tronMailbox: '0x6d5bee57a58e282150c236ed8985550492a69788',
  /** Polymer CrossL2ProverV2 on Tron mainnet (TNKCTuonyurjAXBYpZtSZEo7WdFUKW9cbN). */
  tronCrossL2ProverV2: '0x8769615eb43fa257d2f0b3956a114dcd84117b64',
  /** Next-gen EVM HyperProver (CREATE3, same address on every EVM chain). */
  evmHyperProver: '0xEC03ABb6dE97b153cC31724cd8dA9aA897d1b075',
  /** Next-gen EVM PolymerProver (CREATE3, same address on every EVM chain). */
  evmPolymerProver: '0xEC03E87e167c14B8C89FE5F80DB62b29a5138fC4',
  /**
   * The EVM chains Tron's HyperProver trusts, Hyperlane domain == chainId on each
   * (eco-routes-deployer config/aggregator.json hyperlaneLanes). No Solana, no Tron.
   */
  hyperDomainChainIds: [
    1n,
    10n,
    130n,
    137n,
    143n,
    480n,
    999n,
    2020n,
    5042n,
    8453n,
    9745n,
    42161n,
  ],
} as const

export const HYPER_PROVER_CONSTRUCTOR_TYPES = [
  'address', // mailbox
  'address', // portal
  'bytes32[]', // provers (whitelist)
  'tuple(uint64 domain, uint64 chainId)[]', // domainConfig
]

export const POLYMER_PROVER_CONSTRUCTOR_TYPES = [
  'address', // _portal
  'address', // _crossL2ProverV2
  'uint256', // _maxLogDataSize
  'uint32', // _solanaPolymerChainId
  'uint64', // _solanaChainId
  'bytes32[]', // _proverAddresses (whitelist)
]

export const AGGREGATOR_PROVER_CONSTRUCTOR_TYPES = ['bytes32[]'] // members

const BASE58_TRON = /^T[1-9A-HJ-NP-Za-km-z]{33}$/

const doubleSha256 = (data: Uint8Array): Uint8Array =>
  ethers.getBytes(ethers.sha256(ethers.sha256(data)))

/**
 * A Tron or EVM address as 0x + 40 lowercase hex (no 0x41 prefix). Accepts 0x hex20,
 * 41 + hex20, or base58check `T…` (checksum verified). Refuses the zero address and
 * anything else, so a typo cannot become a constructor argument.
 */
export function parseTronAddress(value: string, field = 'address'): string {
  let hex20: string
  if (/^0x[0-9a-fA-F]{40}$/.test(value)) {
    hex20 = value.toLowerCase()
  } else if (/^41[0-9a-fA-F]{40}$/.test(value)) {
    hex20 = '0x' + value.slice(2).toLowerCase()
  } else if (BASE58_TRON.test(value)) {
    let bytes: Uint8Array
    try {
      bytes = ethers.getBytes(ethers.toBeHex(ethers.decodeBase58(value), 25))
    } catch {
      throw new Error(`${field}: "${value}" does not decode to 25 bytes`)
    }
    if (bytes[0] !== 0x41) {
      throw new Error(
        `${field}: "${value}" is not a 0x41-prefixed Tron address`,
      )
    }
    const checksum = doubleSha256(bytes.slice(0, 21)).slice(0, 4)
    if (ethers.hexlify(checksum) !== ethers.hexlify(bytes.slice(21))) {
      throw new Error(
        `${field}: "${value}" has an invalid base58check checksum`,
      )
    }
    hex20 = ethers.hexlify(bytes.slice(1, 21))
  } else {
    throw new Error(
      `${field}: "${value}" is not a Tron address (0x hex20, 41 + hex20 or base58 T…)`,
    )
  }
  if (BigInt(hex20) === 0n) {
    throw new Error(`${field}: the zero address is not allowed`)
  }
  return hex20
}

/** Base58check `T…` form of a 0x hex20 address. */
export function toTronBase58(hex20: string): string {
  const body = ethers.getBytes(ethers.concat(['0x41', hex20]))
  if (body.length !== 21) throw new Error(`"${hex20}" is not a 20-byte address`)
  return ethers.encodeBase58(
    ethers.concat([body, doubleSha256(body).slice(0, 4)]),
  )
}

/** bytes32(uint256(uint160(addr))): the left-padded form every Whitelist entry uses. */
export const leftPad = (hex20: string): string =>
  ethers.zeroPadValue(hex20.toLowerCase(), 32)

/**
 * Validates whitelist entries: each must be a left-padded, non-zero 20-byte address
 * (top 12 bytes zero). A raw 32-byte Solana key fails this, which is the point: Tron's
 * provers never trust Solana.
 */
export function requireAddressWhitelist(
  field: string,
  entries: readonly string[],
  max = MAX_WHITELIST_SIZE,
): string[] {
  if (entries.length === 0 || entries.length > max) {
    throw new Error(
      `${field}: needs 1 to ${max} entries, got ${entries.length}`,
    )
  }
  const out = entries.map((entry) => {
    if (!/^0x[0-9a-fA-F]{64}$/.test(entry)) {
      throw new Error(`${field}: "${entry}" is not a bytes32`)
    }
    const word = entry.toLowerCase()
    if (BigInt(word) >> 160n !== 0n) {
      throw new Error(
        `${field}: "${entry}" is not a left-padded 20-byte address (a Solana key? Tron↔Solana is closed)`,
      )
    }
    if (BigInt(word) === 0n) throw new Error(`${field}: zero entry`)
    return word
  })
  if (new Set(out).size !== out.length) {
    throw new Error(`${field}: duplicate entry`)
  }
  return out
}

export interface DomainEntry {
  domain: bigint
  chainId: bigint
}

/**
 * The identity Hyperlane domain map (domain == chainId) for the given EVM chains, in the
 * given order. Refuses zero, duplicate, Solana and Tron entries (the constructor itself
 * only refuses zero and duplicates).
 */
export function identityDomainConfig(
  chainIds: readonly bigint[],
): DomainEntry[] {
  if (chainIds.length === 0) throw new Error('domainConfig: no chains')
  const seen = new Set<bigint>()
  return chainIds.map((chainId) => {
    if (chainId <= 0n || chainId >= 1n << 64n) {
      throw new Error(`domainConfig: ${chainId} is not a valid uint64 chain id`)
    }
    if (chainId === SOLANA_CHAIN_ID) {
      throw new Error(
        `domainConfig: ${chainId} is Solana; Tron↔Solana is intentionally closed`,
      )
    }
    if (chainId === TRON_CHAIN_ID) {
      throw new Error(`domainConfig: ${chainId} is Tron itself`)
    }
    if (seen.has(chainId)) {
      throw new Error(`domainConfig: duplicate chain ${chainId}`)
    }
    seen.add(chainId)
    return { domain: chainId, chainId }
  })
}

export interface ConstructorArgs {
  /** The values in constructor order, as ethers encodes them. */
  values: unknown[]
  /** ABI-encoded constructor arguments, 0x-prefixed. */
  encoded: string
}

const encode = (types: string[], values: unknown[]): ConstructorArgs => ({
  values,
  encoded: ethers.AbiCoder.defaultAbiCoder().encode(types, values),
})

export interface HyperProverInput {
  mailbox: string
  portal: string
  /** Remote HyperProvers to trust (0x hex20 or Tron addresses); left-padded here. */
  trustedProvers: readonly string[]
  domainChainIds: readonly bigint[]
}

/** HyperProver(mailbox, portal, provers, domainConfig). */
export function hyperProverConstructorArgs(
  input: HyperProverInput,
): ConstructorArgs & { whitelist: string[]; domains: DomainEntry[] } {
  const mailbox = parseTronAddress(input.mailbox, 'mailbox')
  const portal = parseTronAddress(input.portal, 'portal')
  const whitelist = requireAddressWhitelist(
    'provers',
    input.trustedProvers.map((p) => leftPad(parseTronAddress(p, 'provers'))),
  )
  const domains = identityDomainConfig(input.domainChainIds)
  return {
    ...encode(HYPER_PROVER_CONSTRUCTOR_TYPES, [
      mailbox,
      portal,
      whitelist,
      domains,
    ]),
    whitelist,
    domains,
  }
}

export interface PolymerProverInput {
  portal: string
  crossL2ProverV2: string
  maxLogDataSize: bigint
  solanaPolymerChainId: bigint
  solanaChainId: bigint
  /** Remote PolymerProvers to trust (0x hex20 or Tron addresses); left-padded here. */
  trustedProvers: readonly string[]
}

/**
 * PolymerProver(portal, crossL2ProverV2, maxLogDataSize, solanaPolymerChainId,
 * solanaChainId, whitelist). The Solana ids are required non-zero by the constructor;
 * passing them does not open the Solana lane, which needs the program ID whitelisted.
 */
export function polymerProverConstructorArgs(
  input: PolymerProverInput,
): ConstructorArgs & { whitelist: string[] } {
  const portal = parseTronAddress(input.portal, 'portal')
  const crossL2ProverV2 = parseTronAddress(
    input.crossL2ProverV2,
    'crossL2ProverV2',
  )
  if (input.maxLogDataSize <= 0n || input.maxLogDataSize > 32n * 1024n) {
    throw new Error(
      'maxLogDataSize must be in (0, 32768] (MAX_LOG_DATA_SIZE_GUARD)',
    )
  }
  if (
    input.solanaPolymerChainId <= 0n ||
    input.solanaPolymerChainId >= 1n << 32n
  ) {
    throw new Error('solanaPolymerChainId must be a non-zero uint32')
  }
  if (input.solanaChainId <= 0n || input.solanaChainId >= 1n << 64n) {
    throw new Error('solanaChainId must be a non-zero uint64')
  }
  const whitelist = requireAddressWhitelist(
    'whitelist',
    input.trustedProvers.map((p) => leftPad(parseTronAddress(p, 'whitelist'))),
  )
  return {
    ...encode(POLYMER_PROVER_CONSTRUCTOR_TYPES, [
      portal,
      crossL2ProverV2,
      input.maxLogDataSize,
      input.solanaPolymerChainId,
      input.solanaChainId,
      whitelist,
    ]),
    whitelist,
  }
}

/**
 * AggregatorProver(members): Tron member provers in priority order, each left-padded.
 * Mirrors the constructor's own checks (1..8 members, valid address, no duplicates) so a
 * bad set fails before broadcast; MemberHasNoCode is checked on-chain by
 * `requireLiveMembers`.
 */
export function aggregatorProverConstructorArgs(
  members: readonly string[],
): ConstructorArgs & { members: string[] } {
  const hex = members.map((m, i) => parseTronAddress(m, `member ${i}`))
  const words = requireAddressWhitelist(
    'members',
    hex.map(leftPad),
    AGGREGATOR_MAX_MEMBERS,
  )
  return {
    ...encode(AGGREGATOR_PROVER_CONSTRUCTOR_TYPES, [words]),
    members: hex,
  }
}

/** The next generation's Tron HyperProver: trusts only the EVM HyperProver. */
export const nextGenHyperProverArgs = () =>
  hyperProverConstructorArgs({
    mailbox: NEXT_GEN.tronMailbox,
    portal: NEXT_GEN.portalTron,
    trustedProvers: [NEXT_GEN.evmHyperProver],
    domainChainIds: NEXT_GEN.hyperDomainChainIds,
  })

/** The next generation's Tron PolymerProver: trusts only the EVM PolymerProver. */
export const nextGenPolymerProverArgs = () =>
  polymerProverConstructorArgs({
    portal: NEXT_GEN.portalTron,
    crossL2ProverV2: NEXT_GEN.tronCrossL2ProverV2,
    maxLogDataSize: POLYMER_MAX_LOG_DATA_SIZE,
    solanaPolymerChainId: SOLANA_POLYMER_CHAIN_ID,
    solanaChainId: SOLANA_CHAIN_ID,
    trustedProvers: [NEXT_GEN.evmPolymerProver],
  })

/** The Tron aggregator's members, in priority order, by the proof type each reports. */
export const AGGREGATOR_MEMBER_PROOF_TYPES = [
  'Hyperlane',
  'Polymer',
  'LayerZero',
] as const

/** The on-chain reads `requireLiveMembers` needs; the deploy script backs them with TronWeb. */
export interface MemberProbe {
  hasCode: (hex20: string) => Promise<boolean>
  portal: (hex20: string) => Promise<string>
  proofType: (hex20: string) => Promise<string>
}

/**
 * Refuses unless every member holds code (the constructor would revert with
 * MemberHasNoCode), is bound to `portal`, and reports the expected proof type at its
 * priority slot (Hyperlane, Polymer, LayerZero), so a swapped or stale member is caught
 * before broadcast. Codeless members are reported first and stop the other probes.
 */
export async function requireLiveMembers(
  members: readonly string[],
  probe: MemberProbe,
  expected: { portal: string; proofTypes: readonly string[] },
): Promise<void> {
  const label = (m: string) => `${toTronBase58(m)} (${m})`
  const codeless: string[] = []
  for (const member of members) {
    if (!(await probe.hasCode(member))) codeless.push(label(member))
  }
  if (codeless.length > 0) {
    throw new Error(
      `Aggregator member(s) have no code on Tron: ${codeless.join(', ')}. Deploy them first; the constructor reverts with MemberHasNoCode.`,
    )
  }
  if (members.length !== expected.proofTypes.length) {
    throw new Error(
      `Expected ${expected.proofTypes.length} members (${expected.proofTypes.join(', ')}), got ${members.length}`,
    )
  }
  const problems: string[] = []
  for (const [i, member] of members.entries()) {
    const portal = (await probe.portal(member)).toLowerCase()
    if (portal !== expected.portal.toLowerCase()) {
      problems.push(
        `${label(member)} PORTAL() is ${portal}, expected ${expected.portal}`,
      )
    }
    const proofType = await probe.proofType(member)
    if (proofType !== expected.proofTypes[i]) {
      problems.push(
        `${label(member)} at priority ${i} reports getProofType() "${proofType}", expected "${expected.proofTypes[i]}"`,
      )
    }
  }
  if (problems.length > 0) {
    throw new Error(
      `Aggregator members rejected:\n  - ${problems.join('\n  - ')}`,
    )
  }
}

/** Creation bytecode followed by the encoded constructor arguments. */
export function buildInitCode(bytecode: string, encodedArgs: string): string {
  const creation = bytecode.startsWith('0x') ? bytecode : '0x' + bytecode
  return ethers.hexlify(ethers.concat([creation, encodedArgs]))
}

/** One read-back probe: a view call and the value it must return. */
export interface ReadbackCheck {
  label: string
  signature: string
  argTypes: string[]
  args: unknown[]
  returnType: string
  expected: unknown
}

const domainProbes = (domains: readonly DomainEntry[]): ReadbackCheck[] => [
  ...domains.map((d) => ({
    label: `chainIdByDomain(${d.domain})`,
    signature: 'chainIdByDomain(uint64)',
    argTypes: ['uint64'],
    args: [d.domain],
    returnType: 'uint64',
    expected: d.chainId,
  })),
  // Lanes that must stay unregistered on Tron.
  ...[SOLANA_CHAIN_ID, TRON_CHAIN_ID].map((domain) => ({
    label: `chainIdByDomain(${domain}) unset`,
    signature: 'chainIdByDomain(uint64)',
    argTypes: ['uint64'],
    args: [domain],
    returnType: 'uint64',
    expected: 0n,
  })),
]

const whitelistProbes = (
  self: string,
  whitelist: readonly string[],
): ReadbackCheck[] => [
  {
    label: 'getWhitelist()',
    signature: 'getWhitelist()',
    argTypes: [],
    args: [],
    returnType: 'bytes32[]',
    expected: [...whitelist],
  },
  ...whitelist.flatMap((entry) => [
    {
      label: `isWhitelisted(${entry})`,
      signature: 'isWhitelisted(bytes32)',
      argTypes: ['bytes32'],
      args: [entry],
      returnType: 'bool',
      expected: true,
    },
    // The right-padded form of the same address must not pass: guards a padding mistake.
    {
      label: `isWhitelisted(right-padded ${ethers.dataSlice(entry, 12)}) false`,
      signature: 'isWhitelisted(bytes32)',
      argTypes: ['bytes32'],
      args: [ethers.zeroPadBytes(ethers.dataSlice(entry, 12), 32)],
      returnType: 'bool',
      expected: false,
    },
  ]),
  {
    label: 'isWhitelisted(self) false',
    signature: 'isWhitelisted(bytes32)',
    argTypes: ['bytes32'],
    args: [leftPad(self)],
    returnType: 'bool',
    expected: false,
  },
]

/** What a deployed Tron HyperProver must report. */
export function hyperProverReadback(
  self: string,
  args: ReturnType<typeof hyperProverConstructorArgs>,
): ReadbackCheck[] {
  const [mailbox, portal] = args.values as string[]
  return [
    view('PORTAL()', 'address', portal),
    view('MAILBOX()', 'address', mailbox),
    view('MIN_GAS_LIMIT()', 'uint256', 200_000n),
    view('getProofType()', 'string', 'Hyperlane'),
    ...whitelistProbes(self, args.whitelist),
    ...domainProbes(args.domains),
  ]
}

/** What a deployed Tron PolymerProver must report. */
export function polymerProverReadback(
  self: string,
  args: ReturnType<typeof polymerProverConstructorArgs>,
): ReadbackCheck[] {
  const [portal, crossL2, maxLog, solPolymer, solChain] = args.values as [
    string,
    string,
    bigint,
    bigint,
    bigint,
  ]
  return [
    view('PORTAL()', 'address', portal),
    view('CROSS_L2_PROVER_V2()', 'address', crossL2),
    view('MAX_LOG_DATA_SIZE()', 'uint256', maxLog),
    view('SOLANA_POLYMER_CHAIN_ID()', 'uint32', solPolymer),
    view('SOLANA_CHAIN_ID()', 'uint64', solChain),
    view('getProofType()', 'string', 'Polymer'),
    ...whitelistProbes(self, args.whitelist),
  ]
}

/** What a deployed Tron AggregatorProver must report. */
export function aggregatorProverReadback(
  args: ReturnType<typeof aggregatorProverConstructorArgs>,
): ReadbackCheck[] {
  return [
    view('getMembers()', 'address[]', [...args.members]),
    view('getWhitelist()', 'bytes32[]', args.members.map(leftPad)),
    view('getProofType()', 'string', 'Aggregator'),
  ]
}

function view(
  signature: string,
  returnType: string,
  expected: unknown,
): ReadbackCheck {
  return {
    label: signature,
    signature,
    argTypes: [],
    args: [],
    returnType,
    expected,
  }
}

/** Normalizes a decoded value for comparison (addresses and hex lowercased, arrays mapped). */
export function normalize(value: unknown): unknown {
  if (typeof value === 'string') return value.toLowerCase()
  if (Array.isArray(value)) return value.map(normalize)
  if (value !== null && typeof value === 'object' && 'toArray' in value) {
    return normalize((value as { toArray: () => unknown[] }).toArray())
  }
  return value
}

/** Compares a decoded read-back value with its expectation. */
export const readbackMatches = (actual: unknown, expected: unknown): boolean =>
  JSON.stringify(normalize(actual), (_k, v) =>
    typeof v === 'bigint' ? v.toString() : v,
  ) ===
  JSON.stringify(normalize(expected), (_k, v) =>
    typeof v === 'bigint' ? v.toString() : v,
  )
