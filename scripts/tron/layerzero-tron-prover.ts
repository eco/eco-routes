/**
 * Pure helpers for deploying the Tron LayerZeroProver (PAR-503).
 *
 * The policy is eco-routes-deployer's config/layerzero.json: its EVM chains are the Tron
 * prover's immutable domain map, and its Tron entry gives the endpoint. Everything here
 * must match how the deployer builds the EVM provers, or the two sides will not trust
 * each other.
 */
import { ethers } from 'ethers'

/** LayerZeroProver `minGasLimit`, as the deployer and Deploy.s.sol pass it. */
export const LZ_MIN_GAS_LIMIT = 200_000n

const CONSTRUCTOR_TYPES = [
  'address', // endpoint
  'address', // delegate
  'address', // portal
  'bytes32[]', // provers (whitelist)
  'uint256', // minGasLimit
  'tuple(uint64 domain, uint64 chainId)[]', // domainConfig
]

export interface LayerZeroPolicyChain {
  vm?: string
  eid: number
  endpointV2: string
}

export interface LayerZeroPolicy {
  chains: Record<string, LayerZeroPolicyChain>
}

export interface TronProverArgs {
  /** The EVM LayerZeroProver every EVM chain shares (CREATE3), 0x-hex. */
  evmProver: string
  /** The Tron Portal, 0x-hex (20 bytes, no 0x41 prefix). */
  portal: string
  /** The LZ endpoint delegate: the deploying account, 0x-hex. */
  delegate: string
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

/** Creation code plus the six v2.12 LayerZeroProver constructor args. */
export function buildTronLayerZeroProverInitCode(
  bytecode: string,
  policy: LayerZeroPolicy,
  args: TronProverArgs,
): { initCode: string; endpoint: string; whitelist: string[] } {
  const evmProver = requireAddress('evmProver', args.evmProver)
  const portal = requireAddress('portal', args.portal)
  const delegate = requireAddress('delegate', args.delegate)
  const endpoint = requireAddress(
    'Tron endpointV2',
    tronChain(policy).endpointV2,
  )
  const whitelist = [ethers.zeroPadValue(evmProver, 32)]

  const encoded = ethers.AbiCoder.defaultAbiCoder().encode(CONSTRUCTOR_TYPES, [
    endpoint,
    delegate,
    portal,
    whitelist,
    LZ_MIN_GAS_LIMIT,
    tronDomainConfig(policy),
  ])
  const creation = bytecode.startsWith('0x') ? bytecode : '0x' + bytecode
  return {
    initCode: ethers.hexlify(ethers.concat([creation, encoded])),
    endpoint,
    whitelist,
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
