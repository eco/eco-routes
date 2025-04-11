import { run } from 'hardhat'
import { ethers } from 'ethers'
import { BlockTag, Hex, PublicClient, zeroAddress } from 'viem'

export function isZeroAddress(address: Hex): boolean {
  return address === zeroAddress
}

export async function waitMs(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}
/**
 * Waits for the nonce of a client to update.
 *
 * @param client - The `viem` client instance.
 * @param address - The Ethereum address to monitor.
 * @param currentNonce - The current nonce to compare against.
 * @param pollInterval - The interval (in ms) for polling the nonce (default: NONCE_POLL_INTERVAL).
 * @param txCall - The transaction call to make. Must update the nonce by at least 1 or this function will hang and timeout.
 * @returns A promise that resolves to the updated nonce.
 */
export async function waitForNonceUpdate(
  client: PublicClient,
  address: Hex,
  pollInterval: number,
  txCall: () => Promise<any>,
): Promise<number> {
  const getNonce = async (blockTag: BlockTag) => {
    return await client.getTransactionCount({ address, blockTag })
  }
  const initialNonce = await getNonce('pending')
  const result = await txCall()
  // some nodes in the rpc might not be updated even when the one we hit at first is causing a nonce error down the line
  await new Promise((resolve) => setTimeout(resolve, pollInterval / 10))
  let latestNonce = await getNonce('latest')
  while (latestNonce <= initialNonce) {
    await new Promise((resolve) => setTimeout(resolve, pollInterval))
    latestNonce = await getNonce('latest')
  }
  return result
}

export async function waitBlocks(
  provider: ethers.Provider,
  blocks: number = 5,
) {
  const tillBlock = (await provider.getBlockNumber()) + blocks
  await new Promise<void>((resolve) => {
    provider.on('block', (blockNumber) => {
      if (blockNumber === tillBlock) {
        console.log(
          `finished block ${blockNumber}, after waiting for ${blocks} blocks`,
        )
        resolve()
      }
    })
  })
}

type AsyncFunction = () => Promise<any>

/**
 * This method waits on a function to return a non-falsy value for a certain number of blocks
 *
 * @param func the asyn function to call
 * @param options options for the waitBlocks function
 * @returns the result of the function
 */
export async function retryFunction(
  func: AsyncFunction,
  provider: ethers.Provider,
  ops: { blocks: number } = { blocks: 25 },
) {
  const maxWaitBlock = (await provider.getBlockNumber()) + ops.blocks
  let ans
  let err: Error = new Error('waiting on function failed')
  while (!ans) {
    try {
      ans = await func()
      if (ans) {
        return ans
      }
    } catch (e: any) {
      err = e as any
    }
    const currentBlock = await provider.getBlockNumber()
    if (currentBlock >= maxWaitBlock) {
      console.log('Reached maximum wait time at block: ', currentBlock)
      break
    }
  }
  console.log('Error waiting on function: ', err)
}

export async function verifyContract(
  provider: ethers.Provider,
  contractName: string,
  address: Hex,
  args: any[],
) {
  // wait for 60 for the api endpoint to sync with the rpc
  await waitSeconds(60)
  try {
    await retryFunction(async () => {
      const code = await provider.getCode(address)
      if (code.length > 3) {
        console.log(`${address} has code:`, code.substring(0, 10) + '...')
        return code
      }
      await waitBlocks(provider)
    }, provider)
    await run('verify:verify', {
      address,
      constructorArguments: args,
    })
    console.log(`${contractName} verified at:`, address)
    return await provider.getCode(address)
  } catch (e) {
    console.log(`Error verifying ${contractName}: `, e)
  }
}

export async function waitSeconds(seconds: number) {
  return new Promise<void>((resolve) => {
    setTimeout(() => {
      resolve()
    }, seconds * 1000)
  })
}

export async function execCMD(
  command: string,
  options: {} = {},
): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    // This is running locally so ignore github specific commands
    if (command.includes('>>') && !process.env.GITHUB_ENV) {
      const skipMessage = 'Command contains >>, skipping execution'
      console.log(skipMessage)
      resolve(skipMessage)
    } else {
      const { exec } = require('child_process')
      exec(command, options, (error: any, stdout: any, stderr: any) => {
        if (error) {
          console.error(`exec error: ${error}`)
          console.error(`stderr: ${stderr}`)
          reject(error)
          return
        }
        console.log(stdout)
        resolve(stdout)
      })
    }
  })
}
