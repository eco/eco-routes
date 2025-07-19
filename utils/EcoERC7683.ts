import { AbiCoder } from 'ethers'

import { Call, TokenAmount } from './intent'

// EcoERC7683 specific Route type
export type Route = {
  salt: string
  portal: string
  tokens: TokenAmount[]
  calls: Call[]
}

export type OnchainCrosschainOrderData = {
  destination: number
  route: Route
  creator: string
  prover: string
  nativeValue: bigint
  rewardTokens: TokenAmount[]
}

export type GaslessCrosschainOrderData = {
  destination: number
  portal: string
  routeTokens: TokenAmount[]
  calls: Call[]
  prover: string
  nativeValue: bigint
  rewardTokens: TokenAmount[]
}

export type OnchainCrosschainOrder = {
  fillDeadline: number
  orderDataType: string
  orderData: OnchainCrosschainOrderData
}

const OnchainCrosschainOrderDataStruct = [
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
  { name: 'creator', type: 'address' },
  { name: 'prover', type: 'address' },
  { name: 'nativeValue', type: 'uint256' },
  {
    name: 'rewardTokens',
    type: 'tuple[]',
    components: [
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
  },
]

const GaslessCrosschainOrderDataStruct = [
  { name: 'destination', type: 'uint256' },
  { name: 'portal', type: 'bytes32' },
  {
    name: 'routeTokens',
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
  { name: 'prover', type: 'address' },
  { name: 'nativeValue', type: 'uint256' },
  {
    name: 'rewardTokens',
    type: 'tuple[]',
    components: [
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
  },
]

const OnchainCrosschainOrderStruct = [
  { name: 'fillDeadline', type: 'uint32' },
  { name: 'orderDataType', type: 'bytes32' },
  { name: 'orderData', type: 'bytes' },
]

export async function encodeOnchainCrosschainOrderData(
  onchainCrosschainOrderData: OnchainCrosschainOrderData,
) {
  const abiCoder = AbiCoder.defaultAbiCoder()
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: OnchainCrosschainOrderDataStruct,
      },
    ],
    [onchainCrosschainOrderData],
  )
}

export async function encodeGaslessCrosschainOrderData(
  gaslessCrosschainOrderData: GaslessCrosschainOrderData,
) {
  const abiCoder = AbiCoder.defaultAbiCoder()
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: GaslessCrosschainOrderDataStruct,
      },
    ],
    [gaslessCrosschainOrderData],
  )
}

export async function encodeOnchainCrosschainOrder(
  onchainCrosschainOrder: OnchainCrosschainOrder,
) {
  const abiCoder = AbiCoder.defaultAbiCoder()
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: OnchainCrosschainOrderStruct,
      },
    ],
    [onchainCrosschainOrder],
  )
}
