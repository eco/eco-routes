import { ethers } from 'hardhat'
import { AbiCoder } from 'ethers'
import { MinimalRoute } from './intent'

export type MessageBridgeMessage = {
  inbox: string
  minimalRoutes: MinimalRoute[]
  rewardHashes: string[]
  claimants: string[]
}

const MinimalRouteStruct = [
  { name: 'salt', type: 'bytes32' },
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

const MessageBridgeMessageStruct = [
  { name: 'inbox', type: 'address' },
  {
    name: 'minimalRoutes',
    type: 'tuple[]',
    components: [
      { name: 'salt', type: 'bytes32' },
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
    name: 'rewardHashes',
    type: 'bytes32[]',
  },
  {
    name: 'claimants',
    type: 'address[]',
  },
]

export function encodeMessageBridgeMessage(
  messageBridgeMessage: MessageBridgeMessage,
): string {
  const abiCoder = new AbiCoder()
  return abiCoder.encode(
    [
      {
        type: 'tuple',
        components: MessageBridgeMessageStruct,
      },
    ],
    [messageBridgeMessage],
  )
}
// export function encodeMessageBridgeMessage(
//   inbox: string,
//   minimalRoutes: MinimalRoute[],
//   rewardHashes: string[],
//   claimants: string[],
// ): string {
//   const abiCoder = new AbiCoder()
//   return abiCoder.encode(
//     ['address', 'tuple[]', 'bytes32[]', 'address[]'],
//     [inbox, minimalRoutes, rewardHashes, claimants],
//   )
// }
