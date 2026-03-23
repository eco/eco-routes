/**
 * withdraw-tron-intent.ts
 * Calls withdraw on the Tron Portal for a proven intent.
 *
 * Usage:
 *   set -a && source .env.tron && set +a && npx ts-node scripts/withdraw-tron-intent.ts --testnet
 */

import { TronWeb } from 'tronweb'
import { ethers } from 'ethers'
import 'dotenv/config'

const TRON_PORTAL_BASE58  = 'TLp4t7Lv41iLXEqTuB4fkq7WKqUVxZxRo9'
const TRON_PORTAL_HEX20   = '0x76eedca4f0a7aa6d04db86005d0de0efba73e99e'
const TRON_LZ_PROVER_HEX20 = '0x0d8ac908e4a836b98d8188d8736505fb40062ccc'
const BASE_PORTAL_HEX20   = '0x31A1576A284B2509CdbA9cEc36BD9B67D1a754cB'
const BASE_SEPOLIA_CHAIN_ID = 84532

// Values from the last create-tron-intent run
const INTENT_SALT     = '0x0c20b3323cb6b3550279f1374641c9b42c7ddee4b45eed1bd6b1da3add72bc47'
const INTENT_DEADLINE = 1774292977n

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
  const pk = process.env.PRIVATE_KEY!
  if (!pk) throw new Error('PRIVATE_KEY required')

  const rpcUrl = process.env.TRON_RPC_URL || 'https://api.shasta.trongrid.io'
  const tw = new TronWeb({ fullHost: rpcUrl, privateKey: pk })

  const deployerTronAddr = tw.address.fromPrivateKey(pk) as string
  const deployerHex20 = '0x' + (tw.address.toHex(deployerTronAddr) as string).slice(2)
  console.log(`Wallet: ${deployerTronAddr} (${deployerHex20})`)

  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  // ── Compute routeHash ───────────────────────────────────────────────────
  const route = {
    salt:         INTENT_SALT,
    deadline:     INTENT_DEADLINE,
    portal:       BASE_PORTAL_HEX20,
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
    INTENT_DEADLINE,       // deadline
    deployerHex20,         // creator
    TRON_LZ_PROVER_HEX20,  // prover
    0,                     // nativeAmount
    [],                    // tokens
  ]

  // ── Encode calldata ─────────────────────────────────────────────────────
  const iface = new ethers.Interface(WITHDRAW_ABI)
  const calldata = iface.encodeFunctionData('withdraw', [BASE_SEPOLIA_CHAIN_ID, routeHash, reward])
  const rawParameter = calldata.slice(10)

  console.log('\nCalling withdraw on Tron Portal...')
  const result = await tw.transactionBuilder.triggerSmartContract(
    TRON_PORTAL_BASE58,
    'withdraw(uint64,bytes32,(uint64,address,address,uint256,(address,uint256)[]))',
    { feeLimit: 500_000_000, rawParameter },
    [],
  )

  if (!result.result?.result) {
    throw new Error(`triggerSmartContract failed: ${JSON.stringify(result)}`)
  }

  const signed = await tw.trx.sign(result.transaction)
  const broadcast = await tw.trx.sendRawTransaction(signed)

  if (!broadcast.result) {
    throw new Error(`Broadcast failed: ${JSON.stringify(broadcast)}`)
  }

  console.log(`txId: ${broadcast.txid}`)

  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 3000))
    const info: any = await tw.trx.getTransactionInfo(broadcast.txid)
    if (info?.id) {
      if (info.receipt?.result !== 'SUCCESS') {
        console.error('Transaction failed:', JSON.stringify(info, null, 2))
        process.exit(1)
      }
      console.log(`Confirmed! Energy used: ${info.receipt?.energy_usage_total ?? 'N/A'}`)
      break
    }
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
