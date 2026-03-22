/**
 * create-base-intent.ts
 * Publishes a minimal intent on the Base Portal (no calls, no rewards).
 * Destination: Tron Shasta.
 *
 * Usage:
 *   set -a && source .env.tron && set +a && npx ts-node scripts/create-base-intent.ts --testnet
 */

import { ethers } from 'ethers'
import 'dotenv/config'

const BASE_PORTAL       = '0x31A1576A284B2509CdbA9cEc36BD9B67D1a754cB'
const BASE_LZ_PROVER    = '0x25122417560665F1393847C8591e4b1e4daCbc6D'
const TRON_PORTAL_HEX20 = '0x76eedca4f0a7aa6d04db86005d0de0efba73e99e'

// Tron Shasta chain ID — destination for the intent
const TRON_SHASTA_CHAIN_ID = 2494104990

const PUBLISH_ABI = [
  `function publish(
    tuple(
      uint64 destination,
      tuple(bytes32 salt, uint64 deadline, address portal, uint256 nativeAmount,
            tuple(address token, uint256 amount)[] tokens,
            tuple(address target, bytes data, uint256 value)[] calls) route,
      tuple(uint64 deadline, address creator, address prover, uint256 nativeAmount,
            tuple(address token, uint256 amount)[] tokens) reward
    ) intent
  ) external returns (bytes32 intentHash, address vault)`,
]

async function main() {
  const isTestnet = process.argv.includes('--testnet')

  let pk = process.env.PRIVATE_KEY || ''
  if (pk.startsWith('0x')) pk = pk.slice(2)
  if (!pk) throw new Error('PRIVATE_KEY required')

  const rpcUrl = process.env.BASE_RPC_URL || (isTestnet ? 'https://sepolia.base.org' : '')
  if (!rpcUrl) throw new Error('BASE_RPC_URL required')

  const provider = new ethers.JsonRpcProvider(rpcUrl)
  const wallet   = new ethers.Wallet('0x' + pk, provider)

  const deadline = Math.floor(Date.now() / 1000) + 24 * 60 * 60
  const salt     = ethers.keccak256(ethers.toUtf8Bytes('eco-routes-base-intent-' + Date.now()))

  const intent = {
    destination: TRON_SHASTA_CHAIN_ID,
    route: {
      salt,
      deadline,
      portal:       TRON_PORTAL_HEX20,
      nativeAmount: 0n,
      tokens:       [],
      calls:        [],
    },
    reward: {
      deadline,
      creator:      wallet.address,
      prover:       BASE_LZ_PROVER,
      nativeAmount: 0n,
      tokens:       [],
    },
  }

  console.log('Publishing intent on Base Sepolia...')
  console.log(`  Wallet:      ${wallet.address}`)
  console.log(`  Prover:      ${BASE_LZ_PROVER}`)
  console.log(`  Destination: Tron Shasta (${TRON_SHASTA_CHAIN_ID})`)
  console.log(`  Deadline:    ${new Date(deadline * 1000).toISOString()} (+24h)`)
  console.log(`  Salt:        ${salt}`)

  const portal = new ethers.Contract(BASE_PORTAL, PUBLISH_ABI, wallet)
  const tx = await portal.publish(intent)
  console.log(`\ntx: ${tx.hash}`)
  const receipt = await tx.wait()
  console.log(`confirmed in block ${receipt.blockNumber}`)

  // Decode IntentPublished event
  const intentPublishedTopic = ethers.id(
    'IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])',
  )
  for (const log of receipt.logs) {
    if (log.topics[0] === intentPublishedTopic) {
      const intentHash = log.topics[1]
      console.log(`\nintentHash: ${intentHash}`)
      console.log(`\nCopy these into fulfill-tron-intent.ts:`)
      console.log(`  INTENT_HASH     = '${intentHash}'`)
      console.log(`  INTENT_SALT     = '${salt}'`)
      console.log(`  INTENT_DEADLINE = ${deadline}n`)
      console.log(`  CREATOR_HEX20   = '${wallet.address.toLowerCase()}'`)
      break
    }
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
