/**
 * fulfill-base-intent.ts
 * Calls fulfillAndProve on Base Sepolia for an intent published on Tron.
 *
 * Usage:
 *   set -a && source .env.tron && set +a && npx ts-node scripts/fulfill-base-intent.ts --testnet
 */

import { ethers } from 'ethers'
import 'dotenv/config'

// ── Deployed addresses ──────────────────────────────────────────────────────
const BASE_PORTAL        = '0x31A1576A284B2509CdbA9cEc36BD9B67D1a754cB'
const BASE_LZ_PROVER     = '0x25122417560665F1393847C8591e4b1e4daCbc6D'
const TRON_LZ_PROVER_HEX20 = '0x732e4c4a3d81627e0d343889af186cfc96b76c0b'

// ── Intent values (from create-tron-intent output) ─────────────────────────
const INTENT_HASH  = '0xf086ffeef54297f11bc06632f7e6a72e5545bf7a32196e6f37302a3d00710e0a'
const INTENT_SALT  = '0x76a4cb19d0eb7923a0b09efe2752a973dc824c0b3be68530882ec74f84b6db96'
const INTENT_DEADLINE = 1774189847n  // unix seconds from create-tron-intent output

// Creator (deployer) hex20 on Tron = same private key, Base address format
const CREATOR_HEX20      = '0xffe05fc55f42a9ae9eb97731c1ca1e0aa9030fde'
const TRON_PORTAL_HEX20  = '0x76eedca4f0a7aa6d04db86005d0de0efba73e99e'

// Tron Shasta LayerZero EID
const TRON_SHASTA_EID = 40420n

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
  const isTestnet = process.argv.includes('--testnet')

  let pk = process.env.PRIVATE_KEY || ''
  if (pk.startsWith('0x')) pk = pk.slice(2)
  if (!pk) throw new Error('PRIVATE_KEY required')

  const rpcUrl = process.env.BASE_RPC_URL || (isTestnet ? 'https://sepolia.base.org' : '')
  if (!rpcUrl) throw new Error('BASE_RPC_URL required')

  const provider = new ethers.JsonRpcProvider(rpcUrl)
  const wallet   = new ethers.Wallet('0x' + pk, provider)
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  console.log(`Wallet: ${wallet.address}`)

  // ── Build Route struct (must match exactly what was published on Tron) ──
  // route.portal = destination portal (Base Portal) — Inbox checks route.portal == address(this)
  const route = {
    salt:         INTENT_SALT,
    deadline:     INTENT_DEADLINE,
    portal:       BASE_PORTAL,
    nativeAmount: 0n,
    tokens:       [],
    calls:        [],
  }

  // ── Build Reward struct ─────────────────────────────────────────────────
  const reward = {
    deadline:     INTENT_DEADLINE,
    creator:      CREATOR_HEX20,
    prover:       TRON_LZ_PROVER_HEX20,
    nativeAmount: 0n,
    tokens:       [],
  }

  const rewardHash = ethers.keccak256(
    abiCoder.encode(
      ['tuple(uint64 deadline, address creator, address prover, uint256 nativeAmount, tuple(address token, uint256 amount)[] tokens)'],
      [reward],
    ),
  )
  console.log(`rewardHash: ${rewardHash}`)

  // ── Build UnpackedData for LayerZeroProver ──────────────────────────────
  // sourceChainProver: the Tron LZ Prover (0x-prefixed hex20) encoded as RIGHT-aligned
  // bytes32 — i.e. bytes32(uint256(uint160(addr))). This is the `params.receiver` field
  // in the LZ packet: the contract on Tron that will receive and process the proof message
  // sent from Base. EVM LZ endpoints always encode the receiver right-aligned, and Tron's
  // endpoint accepts the same format.
  //
  // Note: this is the ROUTING address (where to deliver the packet on Tron), not the
  // sender-identity encoding. When Tron later sends a packet to Base, origin.sender for a
  // Tron address is LEFT-aligned (bytes32(bytes20(addr))). That asymmetry explains why the
  // two LayerZeroProver whitelist entries differ — see deploy-base-tron.ts comments.
  const sourceChainProver = ethers.zeroPadValue(TRON_LZ_PROVER_HEX20, 32)

  // LZ type-3 options: [type=3][workerId=1(EXECUTOR)][size=17][optType=1(lzReceive)][gas uint128]
  const gasLimit = 200_000n
  const lzOptions =
    '0x' +
    '0003' +                                               // type 3
    '01' +                                                 // workerId = EXECUTOR
    '0011' +                                               // optionSize = 17
    '01' +                                                 // option type = lzReceive
    gasLimit.toString(16).padStart(32, '0')               // uint128 gas (16 bytes)

  const lzData = abiCoder.encode(
    ['tuple(bytes32 sourceChainProver, bytes options, uint256 gasLimit)'],
    [{ sourceChainProver, options: lzOptions, gasLimit }],
  )

  // ── claimant: wallet address as bytes32 ────────────────────────────────
  const claimant = ethers.zeroPadValue(wallet.address, 32)

  // ── encodedProofs: packed (intentHash[32], claimant[32]) pairs ──────────
  const encodedProofs = ethers.concat([INTENT_HASH, claimant])

  // ── Quote LZ fee ────────────────────────────────────────────────────────
  const proverContract = new ethers.Contract(BASE_LZ_PROVER, FETCH_FEE_ABI, provider)
  const fee: bigint = await proverContract.fetchFee(
    TRON_SHASTA_EID,
    encodedProofs,
    lzData,
  )
  console.log(`LZ fee: ${ethers.formatEther(fee)} ETH`)
  // Add 10% buffer to absorb fee fluctuations between quote and submission
  const feeWithBuffer = fee + fee / 10n

  // ── Send fulfillAndProve ────────────────────────────────────────────────
  const portal = new ethers.Contract(BASE_PORTAL, FULFILL_AND_PROVE_ABI, wallet)

  console.log('\nCalling fulfillAndProve on Base Sepolia...')
  const tx = await portal.fulfillAndProve(
    INTENT_HASH,
    route,
    rewardHash,
    claimant,
    BASE_LZ_PROVER,
    TRON_SHASTA_EID,
    lzData,
    { value: feeWithBuffer },
  )

  console.log(`tx: ${tx.hash}`)
  const receipt = await tx.wait()
  console.log(`confirmed in block ${receipt.blockNumber}`)
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
