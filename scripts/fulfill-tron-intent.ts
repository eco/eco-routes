/**
 * fulfill-tron-intent.ts
 * Calls fulfillAndProve on Tron Shasta for an intent published on Base Sepolia.
 * Sends a LayerZero proof back to Base Sepolia (source chain).
 *
 * Usage:
 *   set -a && source .env.tron && set +a && npx ts-node scripts/fulfill-tron-intent.ts --testnet
 */

import { TronWeb } from 'tronweb'
import { ethers } from 'ethers'
import 'dotenv/config'

// ── Deployed addresses ──────────────────────────────────────────────────────
const TRON_PORTAL_BASE58   = 'TLp4t7Lv41iLXEqTuB4fkq7WKqUVxZxRo9'
const TRON_PORTAL_HEX20    = '0x76eedca4f0a7aa6d04db86005d0de0efba73e99e'
const TRON_LZ_PROVER_HEX20 = '0x732e4c4a3d81627e0d343889af186cfc96b76c0b'
const BASE_LZ_PROVER       = '0x25122417560665F1393847C8591e4b1e4daCbc6D'

// Base Sepolia LayerZero EID (source chain)
const BASE_SEPOLIA_EID = 40245n

// ── Intent values (from create-base-intent output) ─────────────────────────
const INTENT_HASH     = '0xbc8d77d3916d608394e391487ec9f0bb5b44dbb603b0a9063fcecc54add4da5b'
const INTENT_SALT     = '0xdb559d6a07b5d27ca42bb84c1cf3fc56139000d1961f45fd5b2778149253be05'
const INTENT_DEADLINE = 1774238153n
const CREATOR_HEX20   = '0xffe05fc55f42a9ae9eb97731c1ca1e0aa9030fde'

// ── ABI fragments ──────────────────────────────────────────────────────────
const FULFILL_AND_PROVE_ABI = [
  `function fulfillAndProve(
    bytes32 intentHash,
    tuple(bytes32 salt, uint64 deadline, address portal, uint256 nativeAmount,
          tuple(address token, uint256 amount)[] tokens,
          tuple(address target, bytes data, uint256 value)[] calls) route,
    bytes32 rewardHash,
    bytes32 claimant,
    address prover,
    uint64 sourceChainDomainID,
    bytes data
  ) external payable returns (bytes[] memory)`,
]

const FETCH_FEE_ABI = [
  `function fetchFee(
    uint64 domainID,
    bytes encodedProofs,
    bytes data
  ) external view returns (uint256)`,
]

async function main() {
  const pk = process.env.PRIVATE_KEY!
  if (!pk) throw new Error('PRIVATE_KEY required')

  const rpcUrl = process.env.TRON_RPC_URL || 'https://api.shasta.trongrid.io'
  const tw = new TronWeb({ fullHost: rpcUrl, privateKey: pk })

  const deployerTronAddr = tw.address.fromPrivateKey(pk) as string
  const deployerHex20 = '0x' + (tw.address.toHex(deployerTronAddr) as string).slice(2)
  console.log(`Wallet: ${deployerTronAddr} (${deployerHex20})`)

  // Derive Tron base58 address for the LZ Prover
  const tronLZProverBase58 = tw.address.fromHex('41' + TRON_LZ_PROVER_HEX20.slice(2)) as string

  const abiCoder = ethers.AbiCoder.defaultAbiCoder()
  const iface    = new ethers.Interface([...FULFILL_AND_PROVE_ABI, ...FETCH_FEE_ABI])

  // ── Build Route struct (must match exactly what was published on Base) ──
  // route.portal = destination portal (Tron Portal) — Inbox checks route.portal == address(this)
  const route = {
    salt:         INTENT_SALT,
    deadline:     INTENT_DEADLINE,
    portal:       TRON_PORTAL_HEX20,
    nativeAmount: 0n,
    tokens:       [] as any[],
    calls:        [] as any[],
  }

  // ── Build Reward struct ─────────────────────────────────────────────────
  const reward = {
    deadline:     INTENT_DEADLINE,
    creator:      CREATOR_HEX20,
    prover:       BASE_LZ_PROVER,    // prover on source chain (Base)
    nativeAmount: 0n,
    tokens:       [] as any[],
  }

  const rewardHash = ethers.keccak256(
    abiCoder.encode(
      ['tuple(uint64 deadline, address creator, address prover, uint256 nativeAmount, tuple(address token, uint256 amount)[] tokens)'],
      [reward],
    ),
  )
  console.log(`rewardHash: ${rewardHash}`)

  // ── claimant: solver address right-aligned as bytes32 ──────────────────
  const claimant = ethers.zeroPadValue(deployerHex20, 32)

  // ── encodedProofs: packed (intentHash[32], claimant[32]) ────────────────
  const encodedProofs = ethers.concat([INTENT_HASH, claimant])

  // ── Build lzData ────────────────────────────────────────────────────────
  // sourceChainProver: the Base LZ Prover (0x-prefixed hex20 EVM address) encoded as
  // RIGHT-aligned bytes32 — i.e. bytes32(uint256(uint160(addr))). This is the
  // `params.receiver` in the LZ packet: the EVM contract on Base that will receive
  // and process the proof. Tron's LZ endpoint encodes EVM receivers right-aligned.
  //
  // Note: when Base later receives the packet from Tron, origin.sender for the Tron LZ
  // Prover (0x-prefixed hex20) comes through LEFT-aligned — bytes32(bytes20(tronAddr)).
  // That is what the Base LayerZeroProver whitelist stores. See deploy-base-tron.ts.
  const sourceChainProver = ethers.zeroPadValue(BASE_LZ_PROVER, 32)

  // LZ type-3 options: [type=3][workerId=1(EXECUTOR)][size=17][optType=1(lzReceive)][gas uint128]
  const gasLimit = 200_000n
  const lzOptions =
    '0x' +
    '0003' +                                          // type 3
    '01' +                                            // workerId = EXECUTOR
    '0011' +                                          // optionSize = 17
    '01' +                                            // option type = lzReceive
    gasLimit.toString(16).padStart(32, '0')           // uint128 gas (16 bytes)

  const lzData = abiCoder.encode(
    ['tuple(bytes32 sourceChainProver, bytes options, uint256 gasLimit)'],
    [{ sourceChainProver, options: lzOptions, gasLimit }],
  )

  // ── Quote LZ fee from Tron LZ Prover (view call) ───────────────────────
  const feeCalldata = iface.encodeFunctionData('fetchFee', [BASE_SEPOLIA_EID, encodedProofs, lzData])
  const feeRawParam = feeCalldata.slice(10)

  const feeResult: any = await tw.transactionBuilder.triggerConstantContract(
    tronLZProverBase58,
    'fetchFee(uint64,bytes,bytes)',
    { rawParameter: feeRawParam },
    [],
    tw.defaultAddress.hex as string,
  )
  const feeRaw: string = feeResult?.constant_result?.[0]
  if (!feeRaw) throw new Error('fetchFee returned no result — check contract address and ABI')
  const fee = abiCoder.decode(['uint256'], '0x' + feeRaw)[0] as bigint
  console.log(`LZ fee: ${ethers.formatUnits(fee, 6)} TRX (${fee} SUN)`)
  // DVN note: The LZ Labs DVN for Tron Shasta (hex20: 0xC6b1A264D9bB30A8d19575B0Bb3BA525A3a6FC93)
  // is paid on-chain via DVNFeePaid. On testnet the off-chain DVN worker may not actively
  // process Tron→EVM routes — if the proof does not arrive on Base within ~30 min,
  // follow up with the LZ Labs team. On-chain config is correct.

  // Add 10% buffer to absorb fee fluctuations between quote and submission
  const feeWithBuffer = fee + fee / 10n

  // ── Encode fulfillAndProve calldata ─────────────────────────────────────
  const calldata = iface.encodeFunctionData('fulfillAndProve', [
    INTENT_HASH,
    route,
    rewardHash,
    claimant,
    TRON_LZ_PROVER_HEX20,  // prover on this chain (Tron, destination) — sends the LZ message
    BASE_SEPOLIA_EID,       // sourceChainDomainID = LZ EID of source chain (Base Sepolia)
    lzData,
  ])
  const rawParameter = calldata.slice(10)

  console.log('\nCalling fulfillAndProve on Tron Portal...')
  const result = await tw.transactionBuilder.triggerSmartContract(
    TRON_PORTAL_BASE58,
    'fulfillAndProve(bytes32,(bytes32,uint64,address,uint256,(address,uint256)[],(address,bytes,uint256)[]),bytes32,bytes32,address,uint64,bytes)',
    { feeLimit: 500_000_000, callValue: Number(feeWithBuffer), rawParameter },
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

      // Decode IntentFulfilled event to confirm
      const fulfilledTopic = ethers.id('IntentFulfilled(bytes32,bytes32)')
      for (const log of info.log || []) {
        if (log.topics?.[0] === fulfilledTopic.slice(2)) {
          console.log(`Intent fulfilled. intentHash: 0x${log.topics[1]}`)
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
