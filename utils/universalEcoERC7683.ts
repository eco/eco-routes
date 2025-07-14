import { AbiCoder } from 'ethers'
import { UniversalCall, UniversalTokenAmount } from './universalIntent'

// Universal EcoERC7683 Route type with bytes32 for all addresses
export type UniversalRoute = {
  salt: string
  deadline: bigint // uint64
  portal: string // bytes32
  tokens: UniversalTokenAmount[]
  calls: UniversalCall[]
}

export type UniversalOnchainCrosschainOrderData = {
  destination: number
  routeHash?: string // bytes32
  route: UniversalRoute
  creator?: string // bytes32 - for backwards compatibility
  prover?: string // bytes32 - for backwards compatibility
  nativeValue?: bigint // for backwards compatibility
  rewardTokens?: UniversalTokenAmount[] // for backwards compatibility
  reward?: {
    deadline: bigint
    creator: string // bytes32
    prover: string // bytes32
    nativeValue: bigint
    tokens: UniversalTokenAmount[]
  }
}

export type UniversalGaslessCrosschainOrderData = {
  destination: number
  portal: string // bytes32
  routeTokens: UniversalTokenAmount[]
  calls: UniversalCall[]
  prover: string // bytes32
  nativeValue: bigint
  rewardTokens: UniversalTokenAmount[]
}

export type UniversalOnchainCrosschainOrder = {
  fillDeadline: number
  orderDataType: string
  orderData: UniversalOnchainCrosschainOrderData
}

const UniversalOnchainCrosschainOrderDataStruct = [
  { name: 'destination', type: 'uint64' },
  {
    name: 'route',
    type: 'tuple',
    components: [
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
    ],
  },
  { name: 'creator', type: 'bytes32' },
  { name: 'prover', type: 'bytes32' },
  { name: 'nativeValue', type: 'uint256' },
  {
    name: 'rewardTokens',
    type: 'tuple[]',
    components: [
      { name: 'token', type: 'bytes32' },
      { name: 'amount', type: 'uint256' },
    ],
  },
]

const UniversalGaslessCrosschainOrderDataStruct = [
  { name: 'destination', type: 'uint256' },
  { name: 'portal', type: 'bytes32' },
  {
    name: 'routeTokens',
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
  { name: 'prover', type: 'bytes32' },
  { name: 'nativeValue', type: 'uint256' },
  {
    name: 'rewardTokens',
    type: 'tuple[]',
    components: [
      { name: 'token', type: 'bytes32' },
      { name: 'amount', type: 'uint256' },
    ],
  },
]

const UniversalOnchainCrosschainOrderStruct = [
  { name: 'fillDeadline', type: 'uint32' },
  { name: 'orderDataType', type: 'bytes32' },
  { name: 'orderData', type: 'bytes' },
]

export function encodeUniversalOnchainCrosschainOrderData(
  onchainCrosschainOrderData: UniversalOnchainCrosschainOrderData,
) {
  const abiCoder = AbiCoder.defaultAbiCoder()

  // Define the complete OrderData struct as a single tuple type
  const orderDataType =
    'tuple(uint64 destination,bytes32 routeHash,tuple(bytes32 salt,uint64 deadline,bytes32 portal,tuple(bytes32 token,uint256 amount)[] tokens,tuple(bytes32 target,bytes data,uint256 value)[] calls) route,tuple(uint64 deadline,bytes32 creator,bytes32 prover,uint256 nativeValue,tuple(bytes32 token,uint256 amount)[] tokens) reward)'

  return abiCoder.encode(
    [orderDataType],
    [
      {
        destination: onchainCrosschainOrderData.destination,
        routeHash:
          onchainCrosschainOrderData.routeHash ||
          '0x0000000000000000000000000000000000000000000000000000000000000000',
        route: {
          salt: onchainCrosschainOrderData.route.salt,
          deadline: onchainCrosschainOrderData.route.deadline,
          portal: onchainCrosschainOrderData.route.portal,
          tokens: onchainCrosschainOrderData.route.tokens.map((t) => ({
            token: t.token,
            amount: t.amount,
          })),
          calls: onchainCrosschainOrderData.route.calls.map((c) => ({
            target: c.target,
            data: c.data,
            value: c.value,
          })),
        },
        reward: {
          deadline: onchainCrosschainOrderData.reward!.deadline,
          creator: onchainCrosschainOrderData.reward!.creator,
          prover: onchainCrosschainOrderData.reward!.prover,
          nativeValue: onchainCrosschainOrderData.reward!.nativeValue,
          tokens: onchainCrosschainOrderData.reward!.tokens.map((t) => ({
            token: t.token,
            amount: t.amount,
          })),
        },
      },
    ],
  )
}

export function encodeUniversalGaslessCrosschainOrderData(
  gaslessCrosschainOrderData: UniversalGaslessCrosschainOrderData,
) {
  const abiCoder = AbiCoder.defaultAbiCoder()

  // Define types as strings for proper ABI encoding
  const types = [
    'uint256', // destination
    'bytes32', // portal
    'tuple(bytes32,uint256)[]', // routeTokens
    'tuple(bytes32,bytes,uint256)[]', // calls
    'bytes32', // prover
    'uint256', // nativeValue
    'tuple(bytes32,uint256)[]', // rewardTokens
  ]

  return abiCoder.encode(types, [
    gaslessCrosschainOrderData.destination,
    gaslessCrosschainOrderData.portal,
    gaslessCrosschainOrderData.routeTokens.map((t) => [t.token, t.amount]),
    gaslessCrosschainOrderData.calls.map((c) => [c.target, c.data, c.value]),
    gaslessCrosschainOrderData.prover,
    gaslessCrosschainOrderData.nativeValue,
    gaslessCrosschainOrderData.rewardTokens.map((t) => [t.token, t.amount]),
  ])
}

export function encodeUniversalOnchainCrosschainOrder(
  onchainCrosschainOrder: UniversalOnchainCrosschainOrder,
) {
  const abiCoder = AbiCoder.defaultAbiCoder()
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: UniversalOnchainCrosschainOrderStruct,
      },
    ],
    [onchainCrosschainOrder],
  )
}
