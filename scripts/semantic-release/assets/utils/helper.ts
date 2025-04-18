/**
 * @file helper.ts
 * 
 * Helper utilities for common blockchain operations.
 * Contains convenience functions for common interactions with standard
 * contracts like ERC20 tokens.
 */

import { encodeFunctionData, erc20Abi, Hex } from 'viem'

/**
 * Encodes an ERC20 token transfer call
 * Creates properly formatted transaction data for calling the transfer function
 * on an ERC20 token contract.
 * 
 * @param to - The address to send tokens to
 * @param value - The amount of tokens to send (in the token's smallest unit)
 * @returns Hex-encoded function call data ready for a transaction
 */
export function encodeERC20Transfer(to: Hex, value: bigint): Hex {
  return encodeFunctionData({
    abi: erc20Abi,
    functionName: 'transfer',
    args: [to, value],
  })
}
