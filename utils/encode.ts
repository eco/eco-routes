import { DataHexString } from 'ethers/lib.commonjs/utils/data'
import { ethers } from 'hardhat'
import { NumberLike } from '@nomicfoundation/hardhat-network-helpers/dist/src/types.js'
import { keccak256 } from 'ethers'

export async function encodeTransfer(
  to: string,
  value: number,
): Promise<DataHexString> {
  // Contract ABIs
  const erc20ABI = ['function transfer(address to, uint256 value)']
  const abiInterface = new ethers.Interface(erc20ABI)
  const callData = abiInterface.encodeFunctionData('transfer', [to, value])
  return callData
}

export async function encodeTransferNative(
  to: string,
  value: number,
): Promise<DataHexString> {
  const transferNativeABI = [
    'function transferNative(address _to, uint256 value)',
  ]
  const abiInterface = new ethers.Interface(transferNativeABI)
  const callData = abiInterface.encodeFunctionData('transferNative', [
    to,
    value,
  ])
  return callData
}

export async function encodeTransferPayable(
<<<<<<< HEAD
    to: string,
    value: number,
  ): Promise<DataHexString> {
    const transferPayableABI = [
      'function transferPayable(address _to, uint256 value)',
    ]
    const abiInterface = new ethers.Interface(transferPayableABI)
    const callData = abiInterface.encodeFunctionData('transferPayable', [
      to,
      value,
    ])
    return callData
  }
=======
  to: string,
  value: number,
): Promise<DataHexString> {
  const transferPayableABI = [
    'function transferPayable(address _to, uint256 value)',
  ]
  const abiInterface = new ethers.Interface(transferPayableABI)
  const callData = abiInterface.encodeFunctionData('transferPayable', [
    to,
    value,
  ])
  return callData
}
>>>>>>> main

export async function encodeIdentifier(
  counter: number,
  chainid: NumberLike,
): Promise<DataHexString> {
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()
  const encodedData = abiCoder.encode(
    ['uint256', 'uint256'],
    [counter, chainid],
  )
  return keccak256(encodedData)
}
