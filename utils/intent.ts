import { ethers } from 'hardhat'
import { getCreate2Address, keccak256, solidityPacked, AbiCoder } from 'ethers'

export type Call = {
  target: string
  data: string
  value: number
}

export type TokenAmount = {
  token: string
  amount: number
}

export type Route = {
  salt: string
  source: number
  destination: number
  inbox: string
  tokens: TokenAmount[]
  calls: Call[]
}

export type Reward = {
  creator: string
  prover: string
  deadline: number
  nativeValue: bigint
  tokens: TokenAmount[]
}

export type Intent = {
  route: Route
  reward: Reward
}

const RouteStruct = [
  { name: 'salt', type: 'bytes32' },
  { name: 'source', type: 'uint256' },
  { name: 'destination', type: 'uint256' },
  { name: 'inbox', type: 'address' },
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

const RewardStruct = [
  { name: 'creator', type: 'address' },
  { name: 'prover', type: 'address' },
  { name: 'deadline', type: 'uint256' },
  { name: 'nativeValue', type: 'uint256' },
  {
    name: 'tokens',
    type: 'tuple[]',
    components: [
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
  },
]

const IntentStruct = [
  {
    name: 'route',
    type: 'tuple',
    components: [
      { name: 'salt', type: 'bytes32' },
      { name: 'source', type: 'uint256' },
      { name: 'destination', type: 'uint256' },
      { name: 'inbox', type: 'address' },
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
      { name: 'creator', type: 'address' },
      { name: 'prover', type: 'address' },
      { name: 'deadline', type: 'uint256' },
      { name: 'nativeValue', type: 'uint256' },
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
    solidityPacked(['bytes32', 'bytes32'], [routeHash, rewardHash]),
  )

  return { routeHash, rewardHash, intentHash }
}

export async function intentFunderAddress(
  intentSourceAddress: string,
  intent: Intent,
) {
  const vault = await intentVaultAddress(intentSourceAddress, intent)
  const { routeHash } = hashIntent(intent)
  const intentFunderFactory = await ethers.getContractFactory('IntentFunder')
  const abiCoder = AbiCoder.defaultAbiCoder()

  return getCreate2Address(
    intentSourceAddress,
    routeHash,
    keccak256(
      solidityPacked(
        ['bytes', 'bytes'],
        [
          intentFunderFactory.bytecode,
          abiCoder.encode(
            [
              'address',
              {
                type: 'tuple',
                components: RewardStruct,
              },
            ],
            [vault, intent.reward],
          ),
        ],
      ),
    ),
  )
}

export async function intentVaultAddress(
  intentSourceAddress: string,
  intent: Intent,
) {
  const { routeHash, intentHash } = hashIntent(intent)
  const intentVaultFactory = await ethers.getContractFactory('IntentVault')
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
