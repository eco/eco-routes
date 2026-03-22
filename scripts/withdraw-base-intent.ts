/**
 * withdraw-base-intent.ts
 * Calls withdraw on the Base Portal for an intent proven from Tron.
 *
 * Usage:
 *   set -a && source .env.tron && set +a && npx ts-node scripts/withdraw-base-intent.ts --testnet
 */

import { ethers } from 'ethers'
import 'dotenv/config'

const BASE_PORTAL       = '0x31A1576A284B2509CdbA9cEc36BD9B67D1a754cB'
const BASE_LZ_PROVER    = '0x25122417560665F1393847C8591e4b1e4daCbc6D'
const TRON_PORTAL_HEX20 = '0x76eedca4f0a7aa6d04db86005d0de0efba73e99e'

// Tron Shasta chain ID (destination of the intent)
const TRON_SHASTA_CHAIN_ID = 2494104990

// Values from the last create-base-intent run
const INTENT_SALT     = '0xdb559d6a07b5d27ca42bb84c1cf3fc56139000d1961f45fd5b2778149253be05'
const INTENT_DEADLINE = 1774238153n
const CREATOR_HEX20   = '0xffe05fc55f42a9ae9eb97731c1ca1e0aa9030fde'

const WITHDRAW_ABI = [
  {
    type: 'function',
    name: 'withdraw',
    inputs: [
      { name: 'destination', type: 'uint64' },
      { name: 'routeHash', type: 'bytes32' },
      {
        name: 'reward',
        type: 'tuple',
        components: [
          { name: 'deadline', type: 'uint64' },
          { name: 'creator', type: 'address' },
          { name: 'prover', type: 'address' },
          { name: 'nativeAmount', type: 'uint256' },
          { name: 'tokens', type: 'tuple[]', components: [{ name: 'token', type: 'address' }, { name: 'amount', type: 'uint256' }] },
        ],
      },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
]

async function main() {
  let pk = process.env.PRIVATE_KEY || ''
  if (pk.startsWith('0x')) pk = pk.slice(2)
  if (!pk) throw new Error('PRIVATE_KEY required')

  const rpcUrl = process.env.BASE_RPC_URL || 'https://sepolia.base.org'
  const provider = new ethers.JsonRpcProvider(rpcUrl)
  const wallet   = new ethers.Wallet('0x' + pk, provider)
  console.log(`Wallet: ${wallet.address}`)

  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  // ── Compute routeHash ───────────────────────────────────────────────────
  const route = {
    salt:         INTENT_SALT,
    deadline:     INTENT_DEADLINE,
    portal:       TRON_PORTAL_HEX20,
    nativeAmount: 0n,
    tokens:       [] as any[],
    calls:        [] as any[],
  }

  const routeHash = ethers.keccak256(
    abiCoder.encode(
      ['tuple(bytes32 salt, uint64 deadline, address portal, uint256 nativeAmount, tuple(address token, uint256 amount)[] tokens, tuple(address target, bytes data, uint256 value)[] calls)'],
      [route],
    ),
  )
  console.log(`routeHash: ${routeHash}`)

  // ── Build Reward struct ─────────────────────────────────────────────────
  const reward = [
    INTENT_DEADLINE,
    CREATOR_HEX20,
    BASE_LZ_PROVER,
    0,
    [],
  ]

  console.log('\nCalling withdraw on Base Portal...')
  const portal = new ethers.Contract(BASE_PORTAL, WITHDRAW_ABI, wallet)
  const tx = await portal.withdraw(TRON_SHASTA_CHAIN_ID, routeHash, reward)
  console.log(`tx: ${tx.hash}`)
  const receipt = await tx.wait()
  console.log(`Confirmed in block ${receipt.blockNumber}`)
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
