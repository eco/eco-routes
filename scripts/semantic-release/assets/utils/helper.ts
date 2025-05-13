/**
 * @file helper.ts
 *
 * Helper utilities for common blockchain operations.
 * Contains convenience functions for common interactions with standard
 * contracts like ERC20 tokens.
 */

import { encodeFunctionData, erc20Abi, Hex } from 'viem'

/**
 * Encodes an ERC20 token transfer call for use in transactions or intent data.
 * Creates properly formatted transaction data for calling the transfer function
 * on an ERC20 token contract, compatible with both direct transactions and meta-transactions.
 *
 * @param to - The recipient address to send tokens to (must be a valid Ethereum address)
 * @param value - The amount of tokens to send (in the token's smallest unit, usually wei)
 * @returns Hex-encoded function call data ready for a transaction or intent
 *
 * @example
 * // Encode a transfer of 1000 tokens to 0x123...
 * const calldata = encodeERC20Transfer("0x123...", BigInt(1000));
 * // Use in a transaction
 * const tx = { to: tokenAddress, data: calldata, ... };
 */
export function encodeERC20Transfer(to: Hex, value: bigint): Hex {
  return encodeFunctionData({
    abi: erc20Abi,
    functionName: 'transfer',
    args: [to, value],
  })
}
