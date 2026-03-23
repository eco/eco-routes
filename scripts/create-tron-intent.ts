/**
 * create-tron-intent.ts
 * Publishes a minimal intent on the Tron Portal (no calls, no rewards).
 *
 * Usage:
 *   set -a && source .env.tron && set +a && npx ts-node scripts/create-tron-intent.ts --testnet
 */

import { TronWeb } from 'tronweb'
import { ethers } from 'ethers'
import 'dotenv/config'

const TRON_PORTAL_BASE58 = 'TLp4t7Lv41iLXEqTuB4fkq7WKqUVxZxRo9'
const TRON_LZ_PROVER_HEX20 = '0x0d8ac908e4a836b98d8188d8736505fb40062ccc'
const TRON_PORTAL_HEX20 = '0x76eedca4f0a7aa6d04db86005d0de0efba73e99e'

// Base Sepolia chain ID — destination for the intent
const BASE_SEPOLIA_CHAIN_ID = 84532
// Base Sepolia Portal — route.portal must be the DESTINATION portal
const BASE_PORTAL_HEX20 = '0x31A1576A284B2509CdbA9cEc36BD9B67D1a754cB'

const PUBLISH_ABI = [
  {
    type: 'function',
    name: 'publish',
    inputs: [
      {
        name: 'intent',
        type: 'tuple',
        components: [
          { name: 'destination', type: 'uint64' },
          {
            name: 'route',
            type: 'tuple',
            components: [
              { name: 'salt', type: 'bytes32' },
              { name: 'deadline', type: 'uint64' },
              { name: 'portal', type: 'address' },
              { name: 'nativeAmount', type: 'uint256' },
              { name: 'tokens', type: 'tuple[]', components: [{ name: 'token', type: 'address' }, { name: 'amount', type: 'uint256' }] },
              { name: 'calls', type: 'tuple[]', components: [{ name: 'target', type: 'address' }, { name: 'data', type: 'bytes' }, { name: 'value', type: 'uint256' }] },
            ],
          },
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
      },
    ],
    outputs: [
      { name: 'intentHash', type: 'bytes32' },
      { name: 'vault', type: 'address' },
    ],
    stateMutability: 'nonpayable',
  },
]

async function main() {
  const isTestnet = process.argv.includes('--testnet')
  const pk = process.env.PRIVATE_KEY!
  if (!pk) throw new Error('PRIVATE_KEY required')

  const rpcUrl = process.env.TRON_RPC_URL || (isTestnet ? 'https://api.shasta.trongrid.io' : '')
  if (!rpcUrl) throw new Error('TRON_RPC_URL required')

  const tw = new TronWeb({ fullHost: rpcUrl, privateKey: pk })

  const deployerTronAddr = tw.address.fromPrivateKey(pk) as string
  const deployerHex20 = '0x' + (tw.address.toHex(deployerTronAddr) as string).slice(2)

  const deadline = Math.floor(Date.now() / 1000) + 24 * 60 * 60
  const salt = ethers.keccak256(ethers.toUtf8Bytes('eco-routes-tron-intent-' + Date.now()))

  const intent = [
    BASE_SEPOLIA_CHAIN_ID,
    [
      salt,
      deadline,
      BASE_PORTAL_HEX20,
      0,
      [], // tokens
      [], // calls
    ],
    [
      deadline,
      deployerHex20,
      TRON_LZ_PROVER_HEX20,
      0,
      [], // tokens
    ],
  ]

  console.log('Publishing intent on Tron...')
  console.log(`  Creator:     ${deployerTronAddr} (${deployerHex20})`)
  console.log(`  Prover:      ${TRON_LZ_PROVER_HEX20}`)
  console.log(`  Destination: Base Sepolia (${BASE_SEPOLIA_CHAIN_ID})`)
  console.log(`  Deadline:    ${new Date(deadline * 1000).toISOString()} (+24h)`)
  console.log(`  Salt:        ${salt}`)

  // Encode calldata with ethers.js and pass rawParameter to TronWeb
  const iface = new ethers.Interface(PUBLISH_ABI)
  const calldata = iface.encodeFunctionData('publish', [intent])
  const rawParameter = calldata.slice(10) // strip 0x + 4-byte selector

  const result = await tw.transactionBuilder.triggerSmartContract(
    TRON_PORTAL_BASE58,
    'publish((uint64,(bytes32,uint64,address,uint256,(address,uint256)[],(address,bytes,uint256)[]),(uint64,address,address,uint256,(address,uint256)[])))',
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

  console.log(`\ntxId: ${broadcast.txid}`)

  // Wait for receipt and decode intentHash
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 3000))
    const info: any = await tw.trx.getTransactionInfo(broadcast.txid)
    if (info?.id) {
      if (info.receipt?.result !== 'SUCCESS') {
        console.error('Transaction failed:', JSON.stringify(info))
        process.exit(1)
      }
      // Decode IntentPublished event — topic0 = keccak256("IntentPublished(...)")
      const intentPublishedTopic = ethers.id(
        'IntentPublished(bytes32,uint64,bytes,address,address,uint64,uint256,(address,uint256)[])',
      )
      for (const log of info.log || []) {
        if (log.topics?.[0] === intentPublishedTopic.slice(2)) {
          const intentHash = '0x' + log.topics[1]
          console.log(`intentHash: ${intentHash}`)
          break
        }
      }
      break
    }
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
