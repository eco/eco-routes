import { AbiCoder } from 'ethers'

import { Call, TokenAmount, Reward } from './intent'

// EcoERC7683 specific Route type (v3: minTokens solver-input legs, no nativeAmount/tokens)
export type Route = {
  salt: string
  deadline: number
  portal: string
  creator: string
  calls: Call[]
  minTokens: TokenAmount[]
}

// ERC-7683 Output type for maxSpent/minReceived
export type Output = {
  token: string // bytes32
  amount: bigint
  recipient: string // bytes32
  chainId: number
}

// v3 OrderData shape: route is opaque bytes, reward is the v3 rate+flat Reward.
export type OnchainCrosschainOrderData = {
  destination: number
  route: string // encoded route bytes
  reward: Reward
  routePortal: string // bytes32
  routeDeadline: number
  maxSpent: Output[]
}

export type GaslessCrosschainOrderData = {
  destination: number
  route: string // encoded route bytes
  reward: Reward
  routePortal: string // bytes32
  routeDeadline: number
  maxSpent: Output[]
}

export type OnchainCrosschainOrder = {
  fillDeadline: number
  orderDataType: string
  orderData: OnchainCrosschainOrderData
}

// v3 Reward struct: (uint64 deadline, address creator, address prover, RewardToken[] tokens)
// where RewardToken is (address token, uint256 rate, uint256 flat).
const RewardStructComponents = [
  { name: 'deadline', type: 'uint64' },
  { name: 'creator', type: 'address' },
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
]

// ERC-7683 Output struct: (bytes32 token, uint256 amount, bytes32 recipient, uint256 chainId)
const OutputStructComponents = [
  { name: 'token', type: 'bytes32' },
  { name: 'amount', type: 'uint256' },
  { name: 'recipient', type: 'bytes32' },
  { name: 'chainId', type: 'uint256' },
]

// v3 OrderData: route is opaque bytes, reward is the v3 rate+flat Reward.
// struct OrderData { uint64 destination; bytes route; Reward reward; bytes32 routePortal;
//                    uint64 routeDeadline; Output[] maxSpent; }
const OrderDataStructComponents = [
  { name: 'destination', type: 'uint64' },
  { name: 'route', type: 'bytes' },
  { name: 'reward', type: 'tuple', components: RewardStructComponents },
  { name: 'routePortal', type: 'bytes32' },
  { name: 'routeDeadline', type: 'uint64' },
  { name: 'maxSpent', type: 'tuple[]', components: OutputStructComponents },
]

const OnchainCrosschainOrderDataStruct = OrderDataStructComponents

const GaslessCrosschainOrderDataStruct = OrderDataStructComponents

const OnchainCrosschainOrderStruct = [
  { name: 'fillDeadline', type: 'uint32' },
  { name: 'orderDataType', type: 'bytes32' },
  { name: 'orderData', type: 'bytes' },
]

export async function encodeOnchainCrosschainOrderData(
  onchainCrosschainOrderData: OnchainCrosschainOrderData,
) {
  return AbiCoder.defaultAbiCoder().encode(
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
  return AbiCoder.defaultAbiCoder().encode(
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
  return AbiCoder.defaultAbiCoder().encode(
    [
      {
        type: 'tuple',
        components: OnchainCrosschainOrderStruct,
      },
    ],
    [onchainCrosschainOrder],
  )
}
