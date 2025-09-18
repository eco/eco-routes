/**
 * @file intent.ts
 *
 * Intent-related utilities for Eco Routes protocol.
 *
 * This file provides type-safe functions for encoding, decoding, and hashing
 * protocol intent structures. It extracts the necessary type information directly
 * from the contract ABI, ensuring that any contract changes that affect intent
 * structures will be caught at compile time.
 *
 * Key features:
 * - Type-safe encoding and decoding of Route and Reward structures
 * - Intent hashing functions that match the on-chain implementations
 * - TypeScript types derived directly from contract ABI
 */

import {
  Abi,
  decodeAbiParameters,
  encodeAbiParameters,
  encodePacked,
  Hex,
  keccak256,
} from 'viem'
import { PortalAbi } from '../abi'

/**
 * Extracts the functions from an ABI
 */
export type ExtractAbiFunctions<abi extends Abi> = Extract<
  abi[number],
  { type: 'function' }
>

// Define the ABI structures directly based on the Portal contract
// This avoids complex type extraction that can fail with TypeScript

/**
 * Route struct ABI definition
 */
export const RouteAbi = [
  { internalType: 'bytes32', name: 'salt', type: 'bytes32' },
  { internalType: 'uint64', name: 'deadline', type: 'uint64' },
  { internalType: 'address', name: 'portal', type: 'address' },
  { internalType: 'uint256', name: 'nativeAmount', type: 'uint256' },
  {
    components: [
      { internalType: 'address', name: 'token', type: 'address' },
      { internalType: 'uint256', name: 'amount', type: 'uint256' },
    ],
    internalType: 'struct TokenAmount[]',
    name: 'tokens',
    type: 'tuple[]',
  },
  {
    components: [
      { internalType: 'address', name: 'target', type: 'address' },
      { internalType: 'bytes', name: 'data', type: 'bytes' },
      { internalType: 'uint256', name: 'value', type: 'uint256' },
    ],
    internalType: 'struct Call[]',
    name: 'calls',
    type: 'tuple[]',
  },
] as const

/**
 * Reward struct ABI definition
 */
export const RewardAbi = [
  { internalType: 'uint64', name: 'deadline', type: 'uint64' },
  { internalType: 'address', name: 'creator', type: 'address' },
  { internalType: 'address', name: 'prover', type: 'address' },
  { internalType: 'uint256', name: 'nativeAmount', type: 'uint256' },
  {
    components: [
      { internalType: 'address', name: 'token', type: 'address' },
      { internalType: 'uint256', name: 'amount', type: 'uint256' },
    ],
    internalType: 'struct TokenAmount[]',
    name: 'tokens',
    type: 'tuple[]',
  },
] as const

/**
 * Intent struct ABI definition
 */
export const IntentAbi = [
  { internalType: 'uint64', name: 'destination', type: 'uint64' },
  {
    components: RouteAbi,
    internalType: 'struct Route',
    name: 'route',
    type: 'tuple',
  },
  {
    components: RewardAbi,
    internalType: 'struct Reward',
    name: 'reward',
    type: 'tuple',
  },
] as const

// Type aliases for the ABI structures
type Route = typeof RouteAbi
type Reward = typeof RewardAbi
type Intent = typeof IntentAbi

/**
 * The Route struct object - use our defined RouteAbi
 */
const RouteStruct = RouteAbi

/**
 * The Reward struct object - use our defined RewardAbi
 */
const RewardStruct = RewardAbi

/**
 * The Intent struct object - use our defined IntentAbi
 */
const IntentStruct = IntentAbi

/**
 * Define the type for the Route struct based on the RouteAbi
 */
export type RouteType = {
  salt: `0x${string}`
  deadline: bigint
  portal: `0x${string}`
  nativeAmount: bigint
  tokens: readonly { token: `0x${string}`; amount: bigint }[]
  calls: readonly {
    target: `0x${string}`
    data: `0x${string}`
    value: bigint
  }[]
}

/**
 * Define the type for the Reward struct based on the RewardAbi
 */
export type RewardType = {
  deadline: bigint
  creator: `0x${string}`
  prover: `0x${string}`
  nativeAmount: bigint
  tokens: readonly { token: `0x${string}`; amount: bigint }[]
}

/**
 * Define the type for the Intent struct based on the IntentAbi
 */
export type IntentType = {
  destination: bigint
  route: RouteType
  reward: RewardType
}

// Legacy aliases for backwards compatibility
export type EvmRouteType = RouteType
export type EvmRewardType = RewardType

/**
 * Encodes the route parameters into ABI-encoded bytes according to the contract structure.
 * This function ensures proper encoding of route data for protocol interactions.
 *
 * @param route - The route object following the RouteType structure defined by the contract
 * @returns Hex-encoded ABI-encoded representation of the route
 *
 * @example
 * // Encode a route for an intent
 * const encodedRoute = encodeRoute({
 *   fromChain: 1n,
 *   toChain: 10n,
 *   fromToken: '0x1234...',
 *   toToken: '0xabcd...',
 *   amount: 1000000n,
 *   targetAddress: '0x9876...'
 * });
 */
export function encodeRoute(route: RouteType) {
  return encodeAbiParameters(
    [{ type: 'tuple', components: RouteStruct }],
    [route],
  )
}

/**
 * Decodes ABI-encoded route data back into a structured TypeScript RouteType object.
 * This function is the inverse of encodeRoute and extracts a readable route object
 * from its compact binary representation.
 *
 * @param route - Hex-encoded ABI representation of a route structure
 * @returns Decoded RouteType object with all route parameters in their proper types
 *
 * @example
 * // Decode an encoded route back to a route object
 * const route = decodeRoute('0x...');
 * console.log(`Transfer from chain ${route.fromChain} to ${route.toChain}`);
 */
export function decodeRoute(route: Hex): RouteType {
  return decodeAbiParameters(
    [{ type: 'tuple', components: RouteStruct }],
    route,
  )[0]
}

/**
 * Encodes reward parameters into ABI-encoded bytes according to the contract structure.
 * This function creates a properly formatted binary representation of reward data
 * for use in protocol transactions and state verification.
 *
 * @param reward - The reward object following the RewardType structure defined by the contract
 * @returns Hex-encoded ABI-encoded representation of the reward
 *
 * @example
 * // Encode a reward specification for an intent
 * const encodedReward = encodeReward({
 *   rewardToken: '0x1234...',
 *   rewardAmount: 1000000n,
 *   deadline: 1735689600n, // Unix timestamp
 *   recipient: '0x9876...'
 * });
 */
export function encodeReward(reward: RewardType) {
  return encodeAbiParameters(
    [{ type: 'tuple', components: RewardStruct }],
    [reward],
  )
}

/**
 * Decodes ABI-encoded reward data back into a structured TypeScript RewardType object.
 * This function is the inverse of encodeReward and processes binary reward data
 * into a developer-friendly object format with typed properties.
 *
 * @param reward - Hex-encoded ABI representation of a reward structure
 * @returns Decoded RewardType object with all reward parameters in their proper types
 *
 * @example
 * // Decode an encoded reward back to a reward object
 * const reward = decodeReward('0x...');
 * console.log(`Reward of ${reward.rewardAmount} tokens available until ${new Date(Number(reward.deadline) * 1000)}`);
 */
export function decodeReward(reward: Hex): RewardType {
  return decodeAbiParameters(
    [{ type: 'tuple', components: RewardStruct }],
    reward,
  )[0]
}

/**
 * Encodes the complete intent structure (combining route and reward) into packed binary format.
 * This function creates the official on-chain representation of an intent as used by
 * the intent source contract, preserving the exact same encoding as the solidity implementation.
 *
 * @param intent - The intent object containing both route and reward structures
 * @returns Hex-encoded packed representation of the complete intent
 *
 * @example
 * // Encode a complete intent with route and reward
 * const encodedIntent = encodeIntent({
 *   route: { fromChain: 1n, toChain: 10n, ... },
 *   reward: { rewardToken: '0x1234...', rewardAmount: 1000000n, ... }
 * });
 */
export function encodeIntent(intent: IntentType) {
  return encodeAbiParameters(
    [{ type: 'tuple', components: IntentStruct }],
    [intent],
  )
}

/**
 * Decodes a complete intent from its packed binary representation back to a structured object.
 * This function is the inverse of encodeIntent and extracts the full intent data including
 * both route and reward components for client-side processing and validation.
 *
 * @param intent - Hex-encoded packed representation of a complete intent
 * @returns Decoded IntentType object with nested route and reward structures
 *
 * @example
 * // Decode an encoded intent back to an intent object
 * const intent = decodeIntent('0x...');
 * console.log(`Intent: ${intent.route.fromChain} -> ${intent.route.toChain} with reward ${intent.reward.rewardAmount}`);
 */
export function decodeIntent(intent: Hex): IntentType {
  return decodeAbiParameters(
    [{ type: 'tuple', components: IntentStruct }],
    intent,
  )[0]
}

/**
 * Computes the keccak256 hash of an encoded route structure, matching the hashing
 * algorithm used on-chain. This hash uniquely identifies route parameters and
 * can be used for verification and intent matching.
 *
 * @param route - The route object to hash, following the RouteType structure
 * @returns Hex-encoded keccak256 hash of the encoded route
 *
 * @example
 * // Hash a route for verification
 * const routeHash = hashRoute({
 *   fromChain: 1n,
 *   toChain: 10n,
 *   // other route parameters
 * });
 */
export function hashRoute(route: RouteType): Hex {
  return keccak256(encodeRoute(route))
}

/**
 * Computes the keccak256 hash of an encoded reward structure, matching the hashing
 * algorithm used on-chain. This hash uniquely identifies reward parameters and
 * can be used for verification and reward claiming.
 *
 * @param reward - The reward object to hash, following the RewardType structure
 * @returns Hex-encoded keccak256 hash of the encoded reward
 *
 * @example
 * // Hash a reward for verification
 * const rewardHash = hashReward({
 *   rewardToken: '0x1234...',
 *   rewardAmount: 1000000n,
 *   // other reward parameters
 * });
 */
export function hashReward(reward: RewardType): Hex {
  return keccak256(encodeReward(reward))
}

/**
 * Computes all hashes for an intent, including the route hash, reward hash, and
 * the combined intent hash that uniquely identifies the entire intent. This function
 * precisely matches the on-chain hashing algorithms used by the Portal contract.
 *
 * The intent hash is derived from the route and reward hashes (not directly from their structures),
 * ensuring consistency with the on-chain implementation which uses the same approach.
 *
 * @param intent - The complete intent object containing both route and reward structures
 * @returns Object containing the routeHash, rewardHash, and the combined intentHash
 *
 * @example
 * // Generate all hashes for an intent
 * const hashes = hashIntent({
 *   route: { fromChain: 1n, toChain: 10n,  },
 *   reward: { rewardToken: '0x1234...', rewardAmount: 1000000n, }
 * });
 * console.log(`Intent hash: ${hashes.intentHash}`);
 */
export function hashIntent(
  destination: bigint,
  route: RouteType,
  reward: RewardType,
): {
  routeHash: Hex
  rewardHash: Hex
  intentHash: Hex
} {
  const routeHash = hashRoute(route)
  const rewardHash = hashReward(reward)

  const intentHash = keccak256(
    encodePacked(
      ['uint64', 'bytes32', 'bytes32'],
      [destination, routeHash, rewardHash],
    ),
  )

  return {
    routeHash,
    rewardHash,
    intentHash,
  }
}
