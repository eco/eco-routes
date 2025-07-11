import { ethers } from 'hardhat'
import { getCreate2Address, keccak256, solidityPacked, AbiCoder } from 'ethers'
import { TypeCasts } from './typeCasts'

/**
 * Universal Intent types that match the Solidity UniversalIntent.sol definitions
 * All address fields are replaced with bytes32 for cross-chain compatibility
 */

export type UniversalCall = {
  target: string // bytes32
  data: string
  value: number
}

export type UniversalTokenAmount = {
  token: string // bytes32
  amount: number
}

export type UniversalRoute = {
  salt: string
  deadline: number | bigint
  portal: string // bytes32
  tokens: UniversalTokenAmount[]
  calls: UniversalCall[]
}

export type UniversalReward = {
  creator: string // bytes32
  prover: string // bytes32
  deadline: number | bigint
  nativeValue: bigint
  tokens: UniversalTokenAmount[]
}

export type UniversalIntent = {
  destination: number
  route: UniversalRoute
  reward: UniversalReward
}

// Helper functions to convert from address-based to bytes32-based structures
export function convertCallToUniversal(call: {
  target: string
  data: string
  value: number
}): UniversalCall {
  return {
    target: TypeCasts.addressToBytes32(call.target),
    data: call.data,
    value: call.value,
  }
}

export function convertTokenAmountToUniversal(tokenAmount: {
  token: string
  amount: number
}): UniversalTokenAmount {
  return {
    token: TypeCasts.addressToBytes32(tokenAmount.token),
    amount: tokenAmount.amount,
  }
}

export function convertRouteToUniversal(route: {
  salt: string
  deadline: number | bigint
  portal: string
  tokens: { token: string; amount: number }[]
  calls: { target: string; data: string; value: number }[]
}): UniversalRoute {
  return {
    salt: route.salt,
    deadline: route.deadline,
    portal: TypeCasts.addressToBytes32(route.portal),
    tokens: route.tokens.map(convertTokenAmountToUniversal),
    calls: route.calls.map(convertCallToUniversal),
  }
}

export function convertRewardToUniversal(reward: {
  creator: string
  prover: string
  deadline: number | bigint
  nativeValue: bigint
  tokens: { token: string; amount: number }[]
}): UniversalReward {
  return {
    creator: TypeCasts.addressToBytes32(reward.creator),
    prover: TypeCasts.addressToBytes32(reward.prover),
    deadline: reward.deadline,
    nativeValue: reward.nativeValue,
    tokens: reward.tokens.map(convertTokenAmountToUniversal),
  }
}

export function convertIntentToUniversal(intent: {
  destination: number
  route: {
    salt: string
    deadline: number
    portal: string
    tokens: { token: string; amount: number }[]
    calls: { target: string; data: string; value: number }[]
  }
  reward: {
    creator: string
    prover: string
    deadline: number
    nativeValue: bigint
    tokens: { token: string; amount: number }[]
  }
}): UniversalIntent {
  return {
    destination: intent.destination,
    route: convertRouteToUniversal(intent.route),
    reward: convertRewardToUniversal(intent.reward),
  }
}

// ABI encoding structures for UniversalIntent
// Max value for uint64 that works with ethers encoding
export const MAX_UINT64 = 2n ** 64n - 1n
// Max uint64 as a number that JS can't safely represent - use string representation
export const MAX_UINT64_STRING = '18446744073709551615'

const UniversalRouteStruct = [
  { name: 'salt', type: 'bytes32' },
  { name: 'deadline', type: 'uint64' },
  { name: 'portal', type: 'bytes32' },
  {
    name: 'tokens',
    type: 'tuple[]',
    components: [
      { name: 'token', type: 'bytes32' },
      { name: 'amount', type: 'uint256' },
    ],
  },
  {
    name: 'calls',
    type: 'tuple[]',
    components: [
      { name: 'target', type: 'bytes32' },
      { name: 'data', type: 'bytes' },
      { name: 'value', type: 'uint256' },
    ],
  },
]

const UniversalRewardStruct = [
  { name: 'deadline', type: 'uint64' },
  { name: 'creator', type: 'bytes32' },
  { name: 'prover', type: 'bytes32' },
  { name: 'nativeValue', type: 'uint256' },
  {
    name: 'tokens',
    type: 'tuple[]',
    components: [
      { name: 'token', type: 'bytes32' },
      { name: 'amount', type: 'uint256' },
    ],
  },
]

const UniversalIntentStruct = [
  {
    name: 'destination',
    type: 'uint64',
  },
  {
    name: 'route',
    type: 'tuple',
    components: UniversalRouteStruct,
  },
  {
    name: 'reward',
    type: 'tuple',
    components: UniversalRewardStruct,
  },
]

export function encodeUniversalRoute(route: UniversalRoute) {
  const abiCoder = AbiCoder.defaultAbiCoder()
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: UniversalRouteStruct,
      },
    ],
    [route],
  )
}

export function encodeUniversalReward(reward: UniversalReward) {
  const abiCoder = AbiCoder.defaultAbiCoder()
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: UniversalRewardStruct,
      },
    ],
    [reward],
  )
}

export function encodeUniversalIntent(intent: UniversalIntent) {
  const abiCoder = AbiCoder.defaultAbiCoder()
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: UniversalIntentStruct,
      },
    ],
    [intent],
  )
}

export function hashUniversalIntent(intent: UniversalIntent) {
  const routeHash = keccak256(encodeUniversalRoute(intent.route))
  const rewardHash = keccak256(encodeUniversalReward(intent.reward))

  const intentHash = keccak256(
    solidityPacked(
      ['uint64', 'bytes32', 'bytes32'],
      [intent.destination, routeHash, rewardHash],
    ),
  )

  return { routeHash, rewardHash, intentHash }
}

export async function universalIntentVaultAddress(
  intentSourceAddress: string,
  intent: UniversalIntent,
) {
  const { routeHash, intentHash } = hashUniversalIntent(intent)
  const intentVaultFactory = await ethers.getContractFactory('Vault')
  const abiCoder = AbiCoder.defaultAbiCoder()

  return getCreate2Address(
    intentSourceAddress,
    routeHash,
    keccak256(
      solidityPacked(
        ['bytes', 'bytes'],
        [
          intentVaultFactory.bytecode,
          abiCoder.encode(
            [
              'bytes32',
              {
                type: 'tuple',
                components: UniversalRewardStruct,
              },
            ],
            [intentHash, intent.reward],
          ),
        ],
      ),
    ),
  )
}
