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
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: UniversalOnchainCrosschainOrderDataStruct,
      },
    ],
    [onchainCrosschainOrderData],
  )
}

export function encodeUniversalGaslessCrosschainOrderData(
  gaslessCrosschainOrderData: UniversalGaslessCrosschainOrderData,
) {
  const abiCoder = AbiCoder.defaultAbiCoder()
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: UniversalGaslessCrosschainOrderDataStruct,
      },
    ],
    [gaslessCrosschainOrderData],
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