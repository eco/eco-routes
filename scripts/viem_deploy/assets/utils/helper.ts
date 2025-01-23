import { encodeFunctionData, erc20Abi, Hex } from 'viem'

/**
 * Encodes a erc20 transfer
 * @param to the address to send to
 * @param value the amount to send
 * @returns
 */
export function encodeERC20Transfer(to: Hex, value: bigint): Hex {
  return encodeFunctionData({
    abi: erc20Abi,
    functionName: 'transfer',
    args: [to, value],
  })
}
