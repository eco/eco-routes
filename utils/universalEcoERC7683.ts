import { AbiCoder } from 'ethers'
import { UniversalCall, UniversalTokenAmount } from './universalIntent'

// Universal EcoERC7683 Route type with bytes32 for all addresses
export type UniversalRoute = {
  salt: string
  portal: string  // bytes32
  tokens: UniversalTokenAmount[]
  calls: UniversalCall[]
}

export type UniversalOnchainCrosschainOrderData = {
  destination: number
  route: UniversalRoute
  creator: string  // bytes32
  prover: string   // bytes32
  nativeValue: bigint
  rewardTokens: UniversalTokenAmount[]
}

export type UniversalGaslessCrosschainOrderData = {
  destination: number
  portal: string  // bytes32
  routeTokens: UniversalTokenAmount[]
  calls: UniversalCall[]
  prover: string  // bytes32
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
  
  // Define types as strings for proper ABI encoding
  const types = [
    'uint64',     // destination
    'tuple(bytes32,bytes32,tuple(bytes32,uint256)[],tuple(bytes32,bytes,uint256)[])', // route
    'bytes32',    // creator
    'bytes32',    // prover
    'uint256',    // nativeValue
    'tuple(bytes32,uint256)[]'  // rewardTokens
  ]
  
  return abiCoder.encode(
    types,
    [
      onchainCrosschainOrderData.destination,
      [
        onchainCrosschainOrderData.route.salt,
        onchainCrosschainOrderData.route.portal,
        onchainCrosschainOrderData.route.tokens.map(t => [t.token, t.amount]),
        onchainCrosschainOrderData.route.calls.map(c => [c.target, c.data, c.value]),
      ],
      onchainCrosschainOrderData.creator,
      onchainCrosschainOrderData.prover,
      onchainCrosschainOrderData.nativeValue,
      onchainCrosschainOrderData.rewardTokens.map(t => [t.token, t.amount]),
    ],
  )
}

export function encodeUniversalGaslessCrosschainOrderData(
  gaslessCrosschainOrderData: UniversalGaslessCrosschainOrderData,
) {
  const abiCoder = AbiCoder.defaultAbiCoder()
  
  // Define types as strings for proper ABI encoding
  const types = [
    'uint256',    // destination
    'bytes32',    // portal
    'tuple(bytes32,uint256)[]',  // routeTokens
    'tuple(bytes32,bytes,uint256)[]',  // calls
    'bytes32',    // prover
    'uint256',    // nativeValue
    'tuple(bytes32,uint256)[]'  // rewardTokens
  ]
  
  return abiCoder.encode(
    types,
    [
      gaslessCrosschainOrderData.destination,
      gaslessCrosschainOrderData.portal,
      gaslessCrosschainOrderData.routeTokens.map(t => [t.token, t.amount]),
      gaslessCrosschainOrderData.calls.map(c => [c.target, c.data, c.value]),
      gaslessCrosschainOrderData.prover,
      gaslessCrosschainOrderData.nativeValue,
      gaslessCrosschainOrderData.rewardTokens.map(t => [t.token, t.amount]),
    ],
  )
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