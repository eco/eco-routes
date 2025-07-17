import { Address, createPublicClient, Hex, http } from 'viem'
import { optimism } from 'viem/chains'
import { MOCK_INIT_CODE } from './createx'

const ERC2470_CREATE3_ADDRESS =
  '0xC6BAd1EbAF366288dA6FB5689119eDd695a66814' as const

export async function create2470Create3Address(
  deployerAddress: Address,
  salt: Hex,
  bytecode: Hex = MOCK_INIT_CODE,
) {
  // Create a public client for Optimism
  const client = createPublicClient({
    chain: optimism,
    transport: http(),
  })
  return (
    await client.simulateContract({
      address: ERC2470_CREATE3_ADDRESS,
      abi: ERC2470Create3Abi,
      functionName: 'deploy',
      args: [bytecode, salt],
      account: deployerAddress,
      blockNumber: 137292936n, // before it was deployed for salt 2.8
    })
  ).result
}

const ERC2470Create3Abi = [
  {
    inputs: [
      {
        internalType: 'bytes',
        name: 'bytecode',
        type: 'bytes',
      },
      {
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
    ],
    name: 'deploy',
    outputs: [
      {
        internalType: 'address',
        name: 'deployedAddress_',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes',
        name: 'bytecode',
        type: 'bytes',
      },
      {
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
      {
        internalType: 'bytes',
        name: 'init',
        type: 'bytes',
      },
    ],
    name: 'deployAndInit',
    outputs: [
      {
        internalType: 'address',
        name: 'deployedAddress_',
        type: 'address',
      },
    ],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [
      {
        internalType: 'bytes',
        name: 'bytecode',
        type: 'bytes',
      },
      {
        internalType: 'address',
        name: 'sender',
        type: 'address',
      },
      {
        internalType: 'bytes32',
        name: 'salt',
        type: 'bytes32',
      },
    ],
    name: 'deployedAddress',
    outputs: [
      {
        internalType: 'address',
        name: '',
        type: 'address',
      },
    ],
    stateMutability: 'view',
    type: 'function',
  },
] as const
