import {
  concatHex,
  encodeAbiParameters,
  getAddress,
  keccak256,
  slice,
  type Address,
  type Hex,
} from 'viem'

/**
 * Model C chain-parameterized Account salt: `keccak256(abi.encode(bytes32 intentHash, uint64 roleChainId))`.
 * roleChainId is `intent.source` for the escrow account and `intent.destination` for the execution account
 * (they collapse to one salt when source == destination).
 */
export function accountSalt(intentHash: Hex, roleChainId: bigint): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: 'bytes32' }, { type: 'uint64' }],
      [intentHash, roleChainId],
    ),
  )
}

/**
 * Predicts a per-intent Account address (a CREATE2 clone deployed BY the Portal).
 *
 * @param portal            The Portal (the CREATE2 deployer of the clone).
 * @param proxyInitCodeHash `keccak256(Proxy.creationCode ++ abi.encode(accountImplementation))`.
 *   DEPLOYMENT-SPECIFIC: it depends on the compiled `Proxy` creation code and the Account implementation
 *   address the Portal deployed in its constructor. Capture it once per deployment (e.g. from the deploy
 *   artifacts) — it is NOT a universal constant.
 * @param intentHash        The intent hash.
 * @param roleChainId       `intent.source` (escrow) or `intent.destination` (execution).
 * @param prefix            CREATE2 prefix: `0xff` on EVM (default), `0x41` on TRON.
 */
export function predictAccountAddress(params: {
  portal: Address
  proxyInitCodeHash: Hex
  intentHash: Hex
  roleChainId: bigint
  prefix?: Hex
}): Address {
  const { portal, proxyInitCodeHash, intentHash, roleChainId } = params
  const prefix: Hex = params.prefix ?? '0xff'
  const salt = accountSalt(intentHash, roleChainId)
  const hash = keccak256(
    concatHex([prefix, getAddress(portal), salt, proxyInitCodeHash]),
  )
  return getAddress(slice(hash, 12)) // last 20 bytes
}
