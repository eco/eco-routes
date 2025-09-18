import { ethers } from 'hardhat'
import { getCreate2Address, keccak256, solidityPacked, AbiCoder } from 'ethers'

export type Call = {
  target: string
  data: string
  value: number | bigint
}

export type TokenAmount = {
  token: string
  amount: number | bigint
}

export type Route = {
  salt: string
  deadline: number | bigint
  portal: string
  nativeAmount: number | bigint
  tokens: TokenAmount[]
  calls: Call[]
}

export type Reward = {
  creator: string
  prover: string
  deadline: number | bigint
  nativeAmount: bigint
  tokens: TokenAmount[]
}

export type Intent = {
  destination: number
  route: Route
  reward: Reward
}

export const RouteStruct = [
  { name: 'salt', type: 'bytes32' },
  { name: 'deadline', type: 'uint64' },
  { name: 'portal', type: 'address' },
  { name: 'nativeAmount', type: 'uint256' },
  {
    name: 'tokens',
    type: 'tuple[]',
    components: [
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
  },
  {
    name: 'calls',
    type: 'tuple[]',
    components: [
      { name: 'target', type: 'address' },
      { name: 'data', type: 'bytes' },
      { name: 'value', type: 'uint256' },
    ],
  },
]

export const RewardStruct = [
  { name: 'deadline', type: 'uint64' },
  { name: 'creator', type: 'address' },
  { name: 'prover', type: 'address' },
  { name: 'nativeAmount', type: 'uint256' },
  {
    name: 'tokens',
    type: 'tuple[]',
    components: [
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
  },
]

export const IntentStruct = [
  {
    name: 'destination',
    type: 'uint64',
  },
  {
    name: 'route',
    type: 'tuple',
    components: [
      { name: 'salt', type: 'bytes32' },
      { name: 'deadline', type: 'uint64' },
      { name: 'portal', type: 'address' },
      { name: 'nativeAmount', type: 'uint256' },
      {
        name: 'tokens',
        type: 'tuple[]',
        components: [
          { name: 'token', type: 'address' },
          { name: 'amount', type: 'uint256' },
        ],
      },
      {
        name: 'calls',
        type: 'tuple[]',
        components: [
          { name: 'target', type: 'address' },
          { name: 'data', type: 'bytes' },
          { name: 'value', type: 'uint256' },
        ],
      },
    ],
  },
  {
    name: 'reward',
    type: 'tuple',
    components: [
      { name: 'deadline', type: 'uint64' },
      { name: 'creator', type: 'address' },
      { name: 'prover', type: 'address' },
      { name: 'nativeAmount', type: 'uint256' },
      {
        name: 'tokens',
        type: 'tuple[]',
        components: [
          { name: 'token', type: 'address' },
          { name: 'amount', type: 'uint256' },
        ],
      },
    ],
  },
]

export function encodeRoute(route: Route) {
  const abiCoder = AbiCoder.defaultAbiCoder()
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: RouteStruct,
      },
    ],
    [route],
  )
}

export function encodeReward(reward: Reward) {
  const abiCoder = AbiCoder.defaultAbiCoder()
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: RewardStruct,
      },
    ],
    [reward],
  )
}

export function encodeIntent(intent: Intent) {
  const abiCoder = AbiCoder.defaultAbiCoder()
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: IntentStruct,
      },
    ],
    [intent],
  )
}

export function hashIntent(intent: Intent) {
  const routeHash = keccak256(encodeRoute(intent.route))
  const rewardHash = keccak256(encodeReward(intent.reward))

  const intentHash = keccak256(
    solidityPacked(
      ['uint64', 'bytes32', 'bytes32'],
      [intent.destination, routeHash, rewardHash],
    ),
  )

  return { routeHash, rewardHash, intentHash }
}

export async function intentVaultAddress(
  intentSourceAddress: string,
  intent: Intent,
) {
  const { routeHash, intentHash } = hashIntent(intent)
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
                components: RewardStruct,
              },
            ],
            [intentHash, intent.reward],
          ),
        ],
      ),
    ),
  )
}
