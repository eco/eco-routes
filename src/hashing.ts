import {
  encodeAbiParameters,
  encodePacked,
  keccak256,
  type Hex,
} from 'viem'
import type { Intent, Reward, Route, TokenAmount } from './types'

// ABI tuple definitions matching contracts/types/Intent.sol exactly (field order & types are
// load-bearing — abi.encode output must be byte-identical to Solidity).
const ROUTE_ABI = {
  type: 'tuple',
  components: [
    { name: 'salt', type: 'bytes32' },
    { name: 'deadline', type: 'uint64' },
    { name: 'portal', type: 'address' },
    { name: 'keeper', type: 'address' },
    { name: 'runtime', type: 'address' },
    { name: 'payload', type: 'bytes' },
    {
      name: 'minTokens',
      type: 'tuple[]',
      components: [
        { name: 'token', type: 'address' },
        { name: 'amount', type: 'uint256' },
      ],
    },
  ],
} as const

const REWARD_ABI = {
  type: 'tuple',
  components: [
    { name: 'deadline', type: 'uint64' },
    { name: 'keeper', type: 'address' },
    { name: 'prover', type: 'address' },
    {
      name: 'tokens',
      type: 'tuple[]',
      components: [
        { name: 'token', type: 'address' },
        { name: 'rate', type: 'uint256' },
        { name: 'flat', type: 'uint256' },
      ],
    },
    { name: 'hooks', type: 'bytes' },
  ],
} as const

const TOKEN_AMOUNT_ARRAY_ABI = {
  type: 'tuple[]',
  components: [
    { name: 'token', type: 'address' },
    { name: 'amount', type: 'uint256' },
  ],
} as const

/** `keccak256(abi.encode(route))`. */
export function hashRoute(route: Route): Hex {
  return keccak256(encodeAbiParameters([ROUTE_ABI], [route]))
}

/** `keccak256(abi.encode(reward))`. */
export function hashReward(reward: Reward): Hex {
  return keccak256(encodeAbiParameters([REWARD_ABI], [reward]))
}

/** `keccak256(abi.encodePacked(uint64 source, uint64 destination, bytes32 routeHash, bytes32 rewardHash))`. */
export function hashIntentComponents(
  source: bigint,
  destination: bigint,
  routeHash: Hex,
  rewardHash: Hex,
): Hex {
  return keccak256(
    encodePacked(
      ['uint64', 'uint64', 'bytes32', 'bytes32'],
      [source, destination, routeHash, rewardHash],
    ),
  )
}

/** Full intent hash: hashes the route + reward, then combines with source/destination. */
export function hashIntent(intent: Intent): Hex {
  return hashIntentComponents(
    intent.source,
    intent.destination,
    hashRoute(intent.route),
    hashReward(intent.reward),
  )
}

/** `keccak256(abi.encode(bytes32 intentHash, bytes32 claimant, TokenAmount[] fulfilled))`. */
export function hashFulfillment(
  intentHash: Hex,
  claimant: Hex,
  fulfilled: TokenAmount[],
): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: 'bytes32' }, { type: 'bytes32' }, TOKEN_AMOUNT_ARRAY_ABI],
      [intentHash, claimant, fulfilled],
    ),
  )
}
