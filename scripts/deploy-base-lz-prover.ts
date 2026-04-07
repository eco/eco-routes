/**
 * deploy-base-lz-prover.ts
 *
 * Phase-2: Deploy a LayerZeroProver on any EVM chain via CREATE3.
 * The address is deterministic (deployer + salt, no bytecode dependency) and
 * must match the address already whitelisted in the Tron LZ Prover.
 *
 * Because CREATE3 address depends only on deployer wallet + salt (not bytecode
 * or constructor args), the same predicted address is valid on every EVM chain
 * as long as the CREATE3 factory is present and the same wallet/salt are used.
 *
 * Usage:
 *   PRIVATE_KEY=... SALT=routes-lifi-demo \
 *     EVM_RPC_URL=https://mainnet.base.org \
 *     EVM_LZ_ENDPOINT=0x1a44076050125825900e736c501f859c50fE728c \
 *     EVM_PORTAL=0x399Dbd5DF04f83103F77A58cBa2B7c4d3cdede97 \
 *     TRON_LZ_PROVER=0x158be00d6a6e13bbc6b99049255f01330b46daf5 \
 *     npx ts-node scripts/deploy-base-lz-prover.ts
 *
 * Environment variables:
 *   PRIVATE_KEY        — deployer private key (hex, with or without 0x)
 *   SALT               — must match phase-1 (e.g. "routes-lifi-demo")
 *   EVM_RPC_URL        — RPC endpoint for the target EVM chain
 *   EVM_LZ_ENDPOINT    — LZ EndpointV2 address on the target chain
 *   EVM_LZ_DELEGATE    — OApp delegate (default: deployer address)
 *   EVM_PORTAL         — Portal address to embed in the prover constructor
 *   TRON_LZ_PROVER     — Tron LZ Prover hex20 address (goes into whitelist)
 *   EVM_CHAIN_NAME     — (optional) display name, e.g. "Base", "Arbitrum"
 *
 * Predicted address:
 *   The predicted address is printed before deployment and is the same on every
 *   EVM chain (same deployer wallet + same SALT → same CREATE3 output).
 */

import { ethers } from 'ethers'
import fs from 'fs'
import path from 'path'
import 'dotenv/config'

const CREATE3_DEPLOYER = '0xC6BAd1EbAF366288dA6FB5689119eDd695a66814'
const MIN_GAS_LIMIT = 200_000

const CREATE3_ABI = [
  'function deploy(bytes memory bytecode, bytes32 salt) external payable returns (address deployedAddress_)',
  'function deployedAddress(bytes memory bytecode, address sender, bytes32 salt) external view returns (address)',
]

function loadArtifact(contractName: string): { abi: any[]; bytecode: string } {
  const artifactPath = path.join(__dirname, '..', 'out', `${contractName}.sol`, `${contractName}.json`)
  if (!fs.existsSync(artifactPath)) {
    throw new Error(`Artifact not found: ${artifactPath}. Run \`forge build\` first.`)
  }
  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'))
  const bytecode = typeof artifact.bytecode === 'object' ? artifact.bytecode.object : artifact.bytecode
  return { abi: artifact.abi, bytecode }
}

async function main() {
  let privateKey = process.env.PRIVATE_KEY || ''
  if (!privateKey) throw new Error('PRIVATE_KEY required')
  if (privateKey.startsWith('0x')) privateKey = privateKey.slice(2)

  const rpcUrl     = process.env.EVM_RPC_URL || ''
  if (!rpcUrl) throw new Error('EVM_RPC_URL required')

  const lzEndpoint = process.env.EVM_LZ_ENDPOINT || ''
  if (!lzEndpoint) throw new Error('EVM_LZ_ENDPOINT required')

  const portal = process.env.EVM_PORTAL || ''
  if (!portal) throw new Error('EVM_PORTAL required')

  const tronLZProverRaw = process.env.TRON_LZ_PROVER || ''
  if (!tronLZProverRaw) throw new Error('TRON_LZ_PROVER required')

  // Optional second whitelist entry — the EVM LZ Prover's own address (for EVM↔EVM routes)
  const evmLZProverRaw = process.env.EVM_LZ_PROVER || ''

  const chainName = process.env.EVM_CHAIN_NAME || 'EVM chain'

  const provider = new ethers.JsonRpcProvider(rpcUrl)
  const wallet   = new ethers.Wallet('0x' + privateKey, provider)
  const network  = await provider.getNetwork()

  const lzDelegate = process.env.EVM_LZ_DELEGATE || wallet.address

  // Build whitelist — Tron LZ Prover + optionally the EVM LZ Prover itself (for EVM↔EVM routes)
  const tronLZProverBytes32 = ethers.zeroPadValue(tronLZProverRaw.toLowerCase(), 32)
  const crossVmProvers = evmLZProverRaw
    ? [tronLZProverBytes32, ethers.zeroPadValue(evmLZProverRaw.toLowerCase(), 32)]
    : [tronLZProverBytes32]

  const abiCoder = ethers.AbiCoder.defaultAbiCoder()
  const rootSalt = ethers.id(process.env.SALT || 'eco-routes-v1')
  const lzSalt   = ethers.keccak256(abiCoder.encode(['bytes32', 'bytes32'], [rootSalt, ethers.id('LAYERZERO_PROVER')]))

  const create3 = new ethers.Contract(CREATE3_DEPLOYER, CREATE3_ABI, provider)
  const predictedAddr: string = await create3.deployedAddress('0x', wallet.address, lzSalt)

  console.log(`=== Deploy LayerZeroProver — ${chainName} (chainId=${network.chainId}) ===`)
  console.log(`Wallet:            ${wallet.address}`)
  console.log(`RPC:               ${rpcUrl}`)
  console.log(`Salt:              ${process.env.SALT || 'eco-routes-v1'} → lzSalt=${lzSalt.slice(0, 10)}...`)
  console.log(`Predicted address: ${predictedAddr}`)
  console.log(`LZ Endpoint:       ${lzEndpoint}`)
  console.log(`Portal:            ${portal}`)
  console.log(`Delegate:          ${lzDelegate}`)
  console.log(`Whitelist:`)
  for (const e of crossVmProvers) console.log(`  ${e}`)
  console.log()

  // Check if already deployed
  const existing = await provider.getCode(predictedAddr)
  if (existing !== '0x') {
    console.log(`Already deployed at ${predictedAddr} — nothing to do.`)
    return
  }

  const { bytecode } = loadArtifact('LayerZeroProver')
  const creationCode = bytecode.startsWith('0x') ? bytecode : '0x' + bytecode
  const constructorArgs = abiCoder.encode(
    ['address', 'address', 'address', 'bytes32[]', 'uint256'],
    [lzEndpoint, lzDelegate, portal, crossVmProvers, MIN_GAS_LIMIT],
  )
  const initCode = ethers.concat([ethers.getBytes(creationCode), ethers.getBytes(constructorArgs)])

  const create3w = new ethers.Contract(CREATE3_DEPLOYER, CREATE3_ABI, wallet)
  console.log('Deploying via CREATE3...')
  const tx = await create3w.deploy(initCode, lzSalt)
  console.log(`tx: ${tx.hash}`)
  await tx.wait()

  const finalCode = await provider.getCode(predictedAddr)
  if (finalCode === '0x') throw new Error(`Deployment failed — no code at ${predictedAddr}`)

  console.log(`\nLayerZeroProver deployed on ${chainName}!`)
  console.log(`  Address: ${predictedAddr}`)
  console.log(`  tx:      ${tx.hash}`)
  console.log(`\nSet in your env:`)
  console.log(`  LZ_PROVER_${chainName.toUpperCase().replace(/\s+/g, '_')}=${predictedAddr}`)
}

main().catch(err => { console.error(err); process.exitCode = 1 })
