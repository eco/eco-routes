import { Address, createPublicClient, Hex, http, keccak256, concat } from 'viem'
import { optimism } from 'viem/chains'
import { MOCK_INIT_CODE } from './createx'

// Standard ERC2470 Singleton Factory address (same on all chains)
const ERC2470_ADDRESS = '0xce0042B868300000d44A59004Da54A005ffdcf9f' as const

// Custom CREATE3 implementation address
const ERC2470_CREATE3_ADDRESS =
  '0xC6BAd1EbAF366288dA6FB5689119eDd695a66814' as const

/**
 * Deploys a contract using standard ERC2470 CREATE2 functionality.
 *
 * @param deployerAddress - The address that will deploy the contract
 * @param salt - The salt for CREATE2 deployment
 * @param bytecode - The initialization bytecode
 * @returns Promise resolving to the deployed contract address
 */
export async function create2470Create2Address(
  deployerAddress: Address,
  salt: Hex,
  bytecode: Hex = MOCK_INIT_CODE,
): Promise<`0x${string}`> {
  // Create a public client for Optimism
  const client = createPublicClient({
    chain: optimism,
    transport: http(),
  })

  return (
    await client.simulateContract({
      address: ERC2470_ADDRESS,
      abi: ERC2470Abi,
      functionName: 'deploy',
      args: [bytecode, salt],
      account: deployerAddress,
    })
  ).result
}

/**
 * Computes the CREATE2 address using ERC2470 standard formula.
 * This is a pure computation that doesn't require network calls.
 *
 * Formula: keccak256(0xff + factory_address + salt + keccak256(bytecode))[12:]
 *
 * @param salt - The salt for CREATE2 deployment
 * @param bytecode - The initialization bytecode
 * @param factoryAddress - The ERC2470 factory address (defaults to standard address)
 * @returns The computed CREATE2 address
 */
export function create2470ComputeCreate2Address(
  salt: Hex,
  bytecode: Hex,
  factoryAddress: Address = ERC2470_ADDRESS,
): `0x${string}` {
  // Standard CREATE2 formula: keccak256(0xff + factory + salt + keccak256(bytecode))[12:]
  const bytecodeHash = keccak256(bytecode)
  const fullHash = keccak256(
    concat([
      '0xff' as Hex,
      factoryAddress,
      salt,
      bytecodeHash,
    ])
  )

  // Take the last 20 bytes (40 hex characters) and add 0x prefix
  return `0x${fullHash.slice(26)}` as `0x${string}`
}

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

// Standard ERC2470 ABI
const ERC2470Abi = [
  {
    inputs: [
      {
        internalType: 'bytes',
        name: '_initCode',
        type: 'bytes',
      },
      {
        internalType: 'bytes32',
        name: '_salt',
        type: 'bytes32',
      },
    ],
    name: 'deploy',
    outputs: [
      {
        internalType: 'address',
        name: 'deployedAddress',
        type: 'address',
      },
    ],
    stateMutability: 'nonpayable',
    type: 'function',
  },
] as const

// Custom CREATE3 implementation ABI
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
