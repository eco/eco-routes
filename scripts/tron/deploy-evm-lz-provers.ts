/**
 * deploy-evm-lz-provers.ts
 *
 * Deploys a LayerZeroProver to one or more EVM chains using CREATE3, ensuring
 * every chain lands at the same deterministic address. Chain config (LZ endpoint,
 * EID) is read from lzdeployconfigs.json.
 *
 * The script predicts the CREATE3 address before deploying and throws if it does
 * not match EXPECTED_LZ_PROVER.
 *
 * Usage:
 *   PRIVATE_KEY=... ALCHEMY_API_KEY=... \
 *   SALT=... \
 *   PORTAL_CONTRACT=0x... \
 *   EXPECTED_LZ_PROVER=0x... \
 *   WHITELIST=0x000...addr1,0x000...addr2 \
 *     npx ts-node scripts/tron/deploy-evm-lz-provers.ts --chains base,arbitrum,optimism
 *
 *   # Dry run (predict addresses only, no transactions)
 *   ... npx ts-node scripts/tron/deploy-evm-lz-provers.ts --chains base --dry-run
 *
 * Required env vars:
 *   PRIVATE_KEY          secp256k1 private key (hex, with or without 0x)
 *   ALCHEMY_API_KEY      Alchemy API key for EVM RPC
 *   SALT                 Salt string or bytes32 hex used for CREATE3
 *   PORTAL_CONTRACT      Portal address (same on all chains)
 *   EXPECTED_LZ_PROVER   Expected deployed address — prediction must match or script aborts
 *   WHITELIST            Comma-separated bytes32-encoded addresses to whitelist
 *
 * Optional env vars:
 *   LAYERZERO_DELEGATE   LZ delegate (defaults to deployer address)
 *   EVM_CREATE3_DEPLOYER Override CREATE3 factory address
 */

import * as fs from 'fs'
import * as path from 'path'
import { ethers } from 'ethers'
import 'dotenv/config'

// ─── Constants ────────────────────────────────────────────────────────────────

const DEFAULT_CREATE3_DEPLOYER = '0xC6BAd1EbAF366288dA6FB5689119eDd695a66814'
const MIN_GAS_LIMIT = 200_000

const CREATE3_ABI = [
  'function deploy(bytes memory bytecode, bytes32 salt) external payable returns (address deployedAddress_)',
  'function deployedAddress(bytes memory bytecode, address sender, bytes32 salt) external view returns (address)',
]

// ─── RPC helpers ──────────────────────────────────────────────────────────────

const ALCHEMY_SLUGS: Record<number, string> = {
  1:        'eth-mainnet',
  10:       'opt-mainnet',
  137:      'polygon-mainnet',
  999:      'hyperliquid-mainnet',
  9745:     'plasma-mainnet',
  8453:     'base-mainnet',
  42161:    'arb-mainnet',
  84532:    'base-sepolia',
  11155111: 'eth-sepolia',
}

function evmRpcUrl(chainId: number, alchemyKey: string): string {
  const slug = ALCHEMY_SLUGS[chainId]
  if (!slug) throw new Error(`No Alchemy RPC configured for chain ID ${chainId}`)
  return `https://${slug}.g.alchemy.com/v2/${alchemyKey}`
}

// ─── Config ───────────────────────────────────────────────────────────────────

interface ChainDeployConfig {
  chainKey: string
  chainName: string
  chainId: number
  lzEid: number
  addresses: {
    lzEndpoint: string
    [key: string]: any
  }
}

function loadDeployConfigs(): { mainnet: ChainDeployConfig[]; testnet: ChainDeployConfig[] } {
  const p = path.join(__dirname, 'lzdeployconfigs.json')
  return JSON.parse(fs.readFileSync(p, 'utf8'))
}

function findChainConfig(chainKey: string): ChainDeployConfig {
  const { mainnet, testnet } = loadDeployConfigs()
  const cfg = [...mainnet, ...testnet].find(c => c.chainKey === chainKey)
  if (!cfg) throw new Error(`Chain '${chainKey}' not found in lzdeployconfigs.json`)
  return cfg
}

// ─── Artifact ─────────────────────────────────────────────────────────────────

function loadArtifact(contractName: string): { abi: any[]; bytecode: string } {
  const artifactPath = path.join(__dirname, '../..', 'out', `${contractName}.sol`, `${contractName}.json`)
  if (!fs.existsSync(artifactPath)) {
    throw new Error(`Artifact not found: ${artifactPath}. Run \`forge build\` first.`)
  }
  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'))
  const bytecode = typeof artifact.bytecode === 'object' ? artifact.bytecode.object : artifact.bytecode
  return { abi: artifact.abi, bytecode }
}

// ─── Deployer ─────────────────────────────────────────────────────────────────

async function deployOnChain(
  chainCfg: ChainDeployConfig,
  opts: {
    privateKey: string
    alchemyKey: string
    lzSalt: string
    portal: string
    whitelist: string[]
    delegate: string
    create3Deployer: string
    expectedAddress: string
    isDryRun: boolean
  },
): Promise<string> {
  const { privateKey, alchemyKey, lzSalt, portal, whitelist, delegate, create3Deployer, expectedAddress, isDryRun } = opts
  const tag = `[${chainCfg.chainName}]`

  const lzEndpoint = chainCfg.addresses.lzEndpoint
  if (!lzEndpoint) throw new Error(`${tag} lzEndpoint address missing in lzdeployconfigs.json`)

  const provider = new ethers.JsonRpcProvider(evmRpcUrl(chainCfg.chainId, alchemyKey))
  const wallet   = new ethers.Wallet('0x' + privateKey, provider)
  const create3  = new ethers.Contract(create3Deployer, CREATE3_ABI, wallet)

  // Predict address
  const predicted: string = await create3.deployedAddress('0x', wallet.address, lzSalt)
  console.log(`  ${tag} Predicted LZProver: ${predicted}`)

  if (predicted.toLowerCase() !== expectedAddress.toLowerCase()) {
    throw new Error(
      `${tag} Address mismatch!\n` +
      `  Expected:  ${expectedAddress}\n` +
      `  Predicted: ${predicted}`,
    )
  }

  if (isDryRun) {
    console.log(`  ${tag} [DRY RUN] Would deploy at: ${predicted}`)
    return predicted
  }

  // Check if already deployed
  const existingCode = await provider.getCode(predicted)
  if (existingCode !== '0x') {
    console.log(`  ${tag} Already deployed at ${predicted} — skipping`)
    return predicted
  }

  // Build init code
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()
  const { bytecode } = loadArtifact('LayerZeroProver')
  const creationCode = bytecode.startsWith('0x') ? bytecode : '0x' + bytecode
  const constructorArgs = abiCoder.encode(
    ['address', 'address', 'address', 'bytes32[]', 'uint256'],
    [lzEndpoint, delegate, portal, whitelist, MIN_GAS_LIMIT],
  )
  const initCode = ethers.concat([ethers.getBytes(creationCode), ethers.getBytes(constructorArgs)])

  console.log(`  ${tag} Deploying LZProver via CREATE3...`)
  console.log(`  ${tag}   endpoint:  ${lzEndpoint}`)
  console.log(`  ${tag}   delegate:  ${delegate}`)
  console.log(`  ${tag}   portal:    ${portal}`)
  console.log(`  ${tag}   whitelist: ${whitelist.join(', ')}`)

  const tx      = await create3.deploy(initCode, lzSalt)
  const receipt = await tx.wait()
  console.log(`  ${tag} tx: ${receipt.hash}`)

  const deployedCode = await provider.getCode(predicted)
  if (deployedCode === '0x') {
    throw new Error(`${tag} Deployment failed — no code at ${predicted}`)
  }

  console.log(`  ${tag} ✓ LZProver deployed at ${predicted}`)
  return predicted
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  // ── CLI args ──────────────────────────────────────────────────────────────
  const isDryRun  = process.argv.includes('--dry-run')
  const chainsIdx = process.argv.indexOf('--chains')
  const chainsVal = chainsIdx !== -1
    ? process.argv[chainsIdx + 1]
    : process.argv.find(a => a.startsWith('--chains='))?.split('=')[1]

  if (!chainsVal || chainsVal.startsWith('--')) {
    console.error('Usage: npx ts-node scripts/tron/deploy-evm-lz-provers.ts --chains base,arbitrum [--dry-run]')
    process.exitCode = 1
    return
  }

  const chainKeys = chainsVal.split(',').map(s => s.trim().toLowerCase())

  // ── Env vars ──────────────────────────────────────────────────────────────
  let pk = process.env.PRIVATE_KEY || ''
  if (!pk && !isDryRun) throw new Error('PRIVATE_KEY env var required')
  if (pk.startsWith('0x')) pk = pk.slice(2)
  if (!pk) pk = '0'.repeat(64)

  const alchemyKey = process.env.ALCHEMY_API_KEY || ''
  if (!alchemyKey) throw new Error('ALCHEMY_API_KEY env var required')

  const saltInput = process.env.SALT || ''
  if (!saltInput) throw new Error('SALT env var required')
  const rootSalt = saltInput.startsWith('0x') ? saltInput : ethers.id(saltInput)
  const lzSalt = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ['bytes32', 'bytes32'],
      [rootSalt, ethers.id('LAYERZERO_PROVER')],
    ),
  )

  const portal = process.env.PORTAL_CONTRACT || ''
  if (!portal) throw new Error('PORTAL_CONTRACT env var required')

  const expectedAddress = process.env.EXPECTED_LZ_PROVER || ''
  if (!expectedAddress) throw new Error('EXPECTED_LZ_PROVER env var required')

  const whitelistRaw = process.env.WHITELIST || ''
  if (!whitelistRaw) throw new Error('WHITELIST env var required (comma-separated bytes32 addresses)')
  const whitelist = whitelistRaw.split(',').map(s => s.trim())

  const create3Deployer = process.env.EVM_CREATE3_DEPLOYER || DEFAULT_CREATE3_DEPLOYER

  // ── Resolve chains ────────────────────────────────────────────────────────
  const chainConfigs = chainKeys.map(key => findChainConfig(key))

  // Delegate resolved after wallet is known — use a temp provider for address
  const tempWallet = new ethers.Wallet('0x' + pk)
  const delegate   = process.env.LAYERZERO_DELEGATE || tempWallet.address

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log('=== EVM LayerZeroProver Deployment ===')
  console.log(`Mode:             ${isDryRun ? 'DRY RUN' : 'LIVE'}`)
  console.log(`Chains:           ${chainConfigs.map(c => c.chainName).join(', ')}`)
  console.log(`Salt:             ${saltInput} → ${lzSalt}`)
  console.log(`Portal:           ${portal}`)
  console.log(`Expected address: ${expectedAddress}`)
  console.log(`Delegate:         ${delegate}`)
  console.log(`Whitelist:        ${whitelist.join(', ')}`)
  console.log()

  // ── Deploy in parallel ────────────────────────────────────────────────────
  const results = await Promise.allSettled(
    chainConfigs.map(chainCfg =>
      deployOnChain(chainCfg, {
        privateKey: pk,
        alchemyKey,
        lzSalt,
        portal,
        whitelist,
        delegate,
        create3Deployer,
        expectedAddress,
        isDryRun,
      }),
    ),
  )

  // ── Results ───────────────────────────────────────────────────────────────
  console.log('\n=== Deployment Summary ===')
  let hasError = false
  for (let i = 0; i < chainConfigs.length; i++) {
    const result = results[i]
    const name   = chainConfigs[i].chainName
    if (result.status === 'fulfilled') {
      console.log(`  [${name}] ✓ ${result.value}`)
    } else {
      console.error(`  [${name}] ✗ ${result.reason?.message ?? result.reason}`)
      hasError = true
    }
  }

  if (hasError) process.exitCode = 1
}

main().catch(err => { console.error(err); process.exitCode = 1 })
