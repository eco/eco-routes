/**
 * Pure helpers for deploying the Tron LayerZeroProver (PAR-503).
 *
 * The policy is eco-routes-deployer's config/layerzero.json: its EVM chains (planned ones
 * included) are the Tron prover's immutable domain map, and its Tron entry gives the
 * endpoint and the pathway security the constructor pins on every domain. Everything here
 * must match how the deployer builds the EVM provers, or the two sides will not trust
 * each other.
 */
import { ethers } from 'ethers'

/** LayerZeroProver `minGasLimit`, as the deployer and Deploy.s.sol pass it. */
export const LZ_MIN_GAS_LIMIT = 200_000n

const CONSTRUCTOR_TYPES = [
  'address', // endpoint
  'address', // portal
  'bytes32[]', // provers (whitelist)
  'uint256', // minGasLimit
  'tuple(uint64 domain, uint64 chainId)[]', // domainConfig
  'tuple(address sendLibrary, address receiveLibrary, address executor, uint32 maxMessageSize, address[] requiredDVNs, uint64 sendConfirmations, uint64[] receiveConfirmations)', // lzConfig
]

export interface LayerZeroPolicyChain {
  vm?: string
  eid: number
  confirmations: number
  endpointV2: string
  sendUln302: string
  receiveUln302: string
  executor: string
  dvns: Record<string, string>
}

export interface LayerZeroPolicy {
  policy: { requiredDVNs: string[]; maxMessageSize: number }
  chains: Record<string, LayerZeroPolicyChain>
}

export interface TronProverArgs {
  /** The EVM LayerZeroProver every EVM chain shares (CREATE3), 0x-hex. */
  evmProver: string
  /** The Tron Portal, 0x-hex (20 bytes, no 0x41 prefix). */
  portal: string
}

/** The constructor's LayerZeroConfig: what it pins on every domain. */
export interface TronLayerZeroConfig {
  sendLibrary: string
  receiveLibrary: string
  executor: string
  maxMessageSize: bigint
  requiredDVNs: string[]
  sendConfirmations: bigint
  receiveConfirmations: bigint[]
}

const requireAddress = (field: string, value: string): string => {
  if (!ethers.isAddress(value) || BigInt(value) === 0n) {
    throw new Error(
      `${field} must be a non-zero 20-byte 0x address, got "${value}"`,
    )
  }
  return value.toLowerCase()
}

function tronChain(policy: LayerZeroPolicy): LayerZeroPolicyChain {
  const tron = Object.values(policy.chains).find((c) => c.vm === 'tron')
  if (!tron) {
    throw new Error('config/layerzero.json has no Tron chain (vm: "tron")')
  }
  return tron
}

/**
 * The Tron prover's domain map: every EVM chain's eid -> chainId, ordered by chain id —
 * the same ordering the deployer uses for the EVM provers.
 */
export function tronDomainConfig(
  policy: LayerZeroPolicy,
): { domain: bigint; chainId: bigint }[] {
  tronChain(policy)
  return Object.entries(policy.chains)
    .filter(([, c]) => c.vm !== 'tron')
    .map(([chainId, c]) => ({
      domain: BigInt(c.eid),
      chainId: BigInt(chainId),
    }))
    .sort((a, b) => (a.chainId < b.chainId ? -1 : 1))
}

/**
 * The Tron pathway security, as the deployer pins it on the EVM side: Tron's libraries,
 * executor and required DVNs (ascending, as ULN302 requires), Tron's own confirmations
 * for sends, and each origin's confirmations for receives, in domain order.
 */
export function tronLayerZeroConfig(
  policy: LayerZeroPolicy,
): TronLayerZeroConfig {
  const tron = tronChain(policy)
  const requiredDVNs = policy.policy.requiredDVNs
    .map((name) => requireAddress(`Tron DVN ${name}`, tron.dvns[name] ?? ''))
    .sort((a, b) => (BigInt(a) < BigInt(b) ? -1 : 1))
  return {
    sendLibrary: requireAddress('Tron sendUln302', tron.sendUln302),
    receiveLibrary: requireAddress('Tron receiveUln302', tron.receiveUln302),
    executor: requireAddress('Tron executor', tron.executor),
    maxMessageSize: BigInt(policy.policy.maxMessageSize),
    requiredDVNs,
    sendConfirmations: BigInt(tron.confirmations),
    receiveConfirmations: tronDomainConfig(policy).map(({ chainId }) =>
      BigInt(policy.chains[chainId.toString()].confirmations),
    ),
  }
}

/** Creation code plus the LayerZeroProver constructor args. */
export function buildTronLayerZeroProverInitCode(
  bytecode: string,
  policy: LayerZeroPolicy,
  args: TronProverArgs,
): {
  initCode: string
  endpoint: string
  whitelist: string[]
  lzConfig: TronLayerZeroConfig
} {
  const evmProver = requireAddress('evmProver', args.evmProver)
  const portal = requireAddress('portal', args.portal)
  const endpoint = requireAddress(
    'Tron endpointV2',
    tronChain(policy).endpointV2,
  )
  const whitelist = [ethers.zeroPadValue(evmProver, 32)]
  const lzConfig = tronLayerZeroConfig(policy)

  const encoded = ethers.AbiCoder.defaultAbiCoder().encode(CONSTRUCTOR_TYPES, [
    endpoint,
    portal,
    whitelist,
    LZ_MIN_GAS_LIMIT,
    tronDomainConfig(policy),
    lzConfig,
  ])
  const creation = bytecode.startsWith('0x') ? bytecode : '0x' + bytecode
  return {
    initCode: ethers.hexlify(ethers.concat([creation, encoded])),
    endpoint,
    whitelist,
    lzConfig,
  }
}

/** Tron CREATE2: keccak256(0x41 ‖ factory ‖ salt ‖ keccak256(initCode)), low 20 bytes. */
export function predictTronCreate2Address(
  factoryHex20: string,
  salt: string,
  initCode: string,
): string {
  const packed = ethers.concat([
    '0x41',
    factoryHex20,
    salt,
    ethers.keccak256(initCode),
  ])
  return '0x' + ethers.keccak256(packed).slice(-40)
}
