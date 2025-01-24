import {
  encodeAbiParameters,
  encodePacked,
  Hex,
  keccak256,
  getContractAddress,
  Abi,
  ContractFunctionArgs,
  encodeFunctionData,
  decodeAbiParameters,
} from 'viem'
import { extractAbiStruct } from './utils'
import { IntentSourceAbi, IntentVaultBytecode, InboxAbi } from '../abi'

/**
 * Extracts the functions from an ABI
 */
export type ExtractAbiFunctions<abi extends Abi> = Extract<
  abi[number],
  { type: 'function' }
>

/**
 * The getIntentHash function from the IntentSource ABI
 */
type GetIntentHashFunction = Extract<
  ExtractAbiFunctions<typeof IntentSourceAbi>,
  { name: 'getIntentHash' }
>['inputs'][number]

type GetIntentHashFunctionComponents = Extract<
  ExtractAbiFunctions<typeof IntentSourceAbi>,
  { name: 'getIntentHash' }
>['inputs'][number]['components'][number]

/**
 * The Route struct abi
 */
type Route = Extract<
  GetIntentHashFunctionComponents,
  { name: 'route' }
>['components']

/**
 * The Reward struct abi
 */
type Reward = Extract<
  GetIntentHashFunctionComponents,
  { name: 'reward' }
>['components']

/**
 * The Intent struct abi
 */
type Intent = Extract<GetIntentHashFunction, { name: 'intent' }>['components']

/**
 * The Route struct object in the IntentSource ABI
 */
const RouteStruct = extractAbiStruct<typeof IntentSourceAbi, Route>(
  IntentSourceAbi,
  'route',
)

/**
 * The Reward struct object in the IntentSource ABI
 */
const RewardStruct = extractAbiStruct<typeof IntentSourceAbi, Reward>(
  IntentSourceAbi,
  'reward',
)

/**
 * The Reward struct object in the IntentSource ABI
 */
const IntentStruct = extractAbiStruct<typeof IntentSourceAbi, Intent>(
  IntentSourceAbi,
  'intent',
)

/**
 * Define the type for the Intent struct in the IntentSource
 */
export type IntentType = ContractFunctionArgs<
  typeof IntentSourceAbi,
  'pure',
  'getIntentHash'
>[number]

/**
 * Define the type for the Route struct in IntentSource
 */
export type RouteType = IntentType['route']

/**
 * Define the type for the Reward struct in IntentSource
 */
export type RewardType = IntentType['reward']

/**
 * Encodes the route parameters
 * @param route the route to encode
 * @returns
 */
export function encodeRoute(route: RouteType) {
  return encodeAbiParameters(
    [{ type: 'tuple', components: RouteStruct }],
    [route],
  )
}

/**
 * Decodes the route hex
 * @param route the route to decode
 * @returns
 */
export function decodeRoute(route: Hex): RouteType {
  return decodeAbiParameters(
    [{ type: 'tuple', components: RouteStruct }],
    route,
  )[0]
}

/**
 * Encodes the reward parameters
 * @param reward the reward to encode
 * @returns
 */
export function encodeReward(reward: RewardType) {
  return encodeAbiParameters(
    [{ type: 'tuple', components: RewardStruct }],
    [reward],
  )
}

/**
 * Decodes the reward hex
 * @param reward the reward to decode
 * @returns
 */
export function decodeReward(reward: Hex): RewardType {
  return decodeAbiParameters(
    [{ type: 'tuple', components: RewardStruct }],
    reward,
  )[0]
}

/**
 * Encodes the intent parameters
 * @param intent the intent to encode
 * @returns
 */
export function encodeIntent(intent: IntentType) {
  return encodePacked(IntentStruct, [intent.route, intent.reward])
}

/**
 * Decodes the intent hex
 * @param intent the intent to decode
 * @returns
 */
export function decodeIntent(intent: Hex): IntentType {
  return decodeAbiParameters(
    [{ type: 'tuple', components: IntentStruct }],
    intent,
  )[0]
}

/**
 * Encodes a transferNative function call
 * @param to the address to send to
 * @param value the amount to send
 */
export function encodeTransferNative(to: Hex, value: bigint): Hex {
  return encodeFunctionData({
    abi: InboxAbi,
    functionName: 'transferNative',
    args: [to, value],
  })
}

/**
 * Hashes the route of an intent
 * @param route the route to hash
 * @returns
 */
export function hashRoute(route: RouteType): Hex {
  return keccak256(encodeRoute(route))
}

/**
 * Hashes the reward of an intent
 * @param reward the reward to hash
 * @returns
 */
export function hashReward(reward: RewardType): Hex {
  return keccak256(encodeReward(reward))
}

/**
 * Hashes the intent and its sub structs
 * @param intent the intent to hash
 * @returns
 */
export function hashIntent(intent: IntentType): {
  routeHash: Hex
  rewardHash: Hex
  intentHash: Hex
} {
  const routeHash = hashRoute(intent.route)
  const rewardHash = hashReward(intent.reward)

  const intentHash = keccak256(
    encodePacked(['bytes32', 'bytes32'], [routeHash, rewardHash]),
  )

  return {
    routeHash,
    rewardHash,
    intentHash,
  }
}

/**
 * Generates the intent vault address using CREATE2
 * @param intentSourceAddress the intent source address
 * @param intent the intent
 * @returns
 */
export function intentVaultAddress(
  intentSourceAddress: Hex,
  intent: IntentType,
): Hex {
  const { routeHash } = hashIntent(intent)

  return getContractAddress({
    opcode: 'CREATE2',
    from: intentSourceAddress,
    salt: routeHash,
    bytecode: IntentVaultBytecode,
  })
}
