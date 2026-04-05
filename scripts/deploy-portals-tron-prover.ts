/**
 * deploy-portals-tron-prover.ts
 *
 * Phase-1 deployment: deploys Portals on both chains and the Tron LayerZeroProver,
 * but does NOT deploy the Base LayerZeroProver yet.
 *
 * Deployed contracts (3 total):
 *   1. Base Portal      (CREATE3)
 *   2. Tron Portal      (direct createSmartContract)
 *   3. Tron LayerZeroProver (CREATE2 via factory, whitelist = predicted Base LZ Prover)
 *
 * The Base LayerZeroProver address is predicted (CREATE3, view call only) and printed
 * so it can be passed to deploy-base-lz-prover.ts in a subsequent step.
 *
 * Usage:
 *   # Dry run
 *   SALT=eco-routes-v1 BASE_LZ_ENDPOINT=0x... TRON_LZ_ENDPOINT=T... \
 *     npx ts-node scripts/deploy-portals-tron-prover.ts --testnet --dry-run
 *
 *   # Live deployment
 *   PRIVATE_KEY=... SALT=eco-routes-v1 BASE_LZ_ENDPOINT=0x... TRON_LZ_ENDPOINT=T... \
 *     npx ts-node scripts/deploy-portals-tron-prover.ts --testnet
 *
 * Environment variables:
 *   PRIVATE_KEY            — deployer private key (hex, with or without 0x)
 *   SALT                   — human-readable salt string (e.g. "eco-routes-v1")
 *   BASE_RPC_URL           — Base RPC endpoint (default: https://sepolia.base.org on --testnet)
 *   TRON_RPC_URL           — Tron RPC endpoint (default: https://api.shasta.trongrid.io on --testnet)
 *   BASE_LZ_ENDPOINT       — LZ EndpointV2 address on Base (0x-prefixed)
 *   TRON_LZ_ENDPOINT       — LZ endpoint address on Tron (base58 or hex)
 *   BASE_LZ_DELEGATE       — delegate for Base LZ Prover (default: deployer)
 *   TRON_LZ_DELEGATE       — delegate for Tron LZ Prover (default: deployer)
 *   TRON_CREATE2_FACTORY   — Create2Factory_Tron address (default: Shasta factory on --testnet)
 *   BASE_PORTAL_CONTRACT   — skip Base Portal deploy, use this existing address
 *   TRON_PORTAL_CONTRACT   — skip Tron Portal deploy, use this existing address
 */

import { TronWeb } from 'tronweb'
import { ethers } from 'ethers'
import fs from 'fs'
import path from 'path'
import 'dotenv/config'

// ─── Constants ────────────────────────────────────────────────────────────────

const CREATE3_DEPLOYER = '0xC6BAd1EbAF366288dA6FB5689119eDd695a66814'
const MIN_GAS_LIMIT = 200_000

const TRON_SHASTA_CREATE2_FACTORY = 'TSh1WRYebthHLcfJ7eFqTyps97jMgbh96g'
const DEPLOYED_TOPIC = ethers.id('Deployed(address,bytes32)')

const TRON_MAINNET_CHAIN_ID = 728126428
const TRON_SHASTA_CHAIN_ID = 2494104990
const TRON_NILE_CHAIN_ID = 3448148188

const CREATE3_ABI = [
  'function deploy(bytes memory bytecode, bytes32 salt) external payable returns (address deployedAddress_)',
  'function deployedAddress(bytes memory bytecode, address sender, bytes32 salt) external view returns (address)',
]

// ─── Utilities ────────────────────────────────────────────────────────────────

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms))
}

function loadArtifact(contractName: string): { abi: any[]; bytecode: string } {
  const artifactPath = path.join(__dirname, '..', 'out', `${contractName}.sol`, `${contractName}.json`)
  if (!fs.existsSync(artifactPath)) {
    throw new Error(`Artifact not found: ${artifactPath}. Run \`forge build\` first.`)
  }
  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'))
  const bytecode = typeof artifact.bytecode === 'object' ? artifact.bytecode.object : artifact.bytecode
  return { abi: artifact.abi, bytecode }
}

function predictCreate2Tron(factory20hex: string, salt: string, bytecodeHash: string): string {
  const packed = ethers.concat([
    new Uint8Array([0x41]),
    ethers.getBytes(factory20hex),
    ethers.getBytes(salt),
    ethers.getBytes(bytecodeHash),
  ])
  return '0x' + ethers.keccak256(packed).slice(-40)
}

function tronAddrToHex20(tronWeb: TronWeb, addr: string): string {
  if (!addr) return ''
  if (addr.startsWith('0x')) return addr.toLowerCase()
  if (addr.startsWith('41')) return ('0x' + addr.slice(2)).toLowerCase()
  const hex41 = tronWeb.address.toHex(addr) as string
  return ('0x' + hex41.slice(2)).toLowerCase()
}

// ─── BaseDeployer ─────────────────────────────────────────────────────────────

class BaseDeployer {
  private provider: ethers.JsonRpcProvider
  private wallet: ethers.Wallet
  private abiCoder: ethers.AbiCoder

  constructor(rpcUrl: string, privateKey: string) {
    this.provider = new ethers.JsonRpcProvider(rpcUrl)
    this.wallet = new ethers.Wallet(privateKey, this.provider)
    this.abiCoder = ethers.AbiCoder.defaultAbiCoder()
  }

  get address(): string { return this.wallet.address }

  async predictPortalAddress(portalSalt: string): Promise<string> {
    const create3 = new ethers.Contract(CREATE3_DEPLOYER, CREATE3_ABI, this.provider)
    return await create3.deployedAddress('0x', this.wallet.address, portalSalt)
  }

  async deployPortal(portalSalt: string, existingPortal?: string): Promise<string> {
    if (existingPortal) {
      console.log(`  Using existing Base Portal: ${existingPortal}`)
      return existingPortal
    }
    const predictedAddr = await this.predictPortalAddress(portalSalt)
    console.log(`  Predicted address: ${predictedAddr}`)
    const code = await this.provider.getCode(predictedAddr)
    if (code !== '0x') {
      console.log(`  Already deployed at: ${predictedAddr}`)
      return predictedAddr
    }
    const { bytecode } = loadArtifact('Portal')
    const creationCode = bytecode.startsWith('0x') ? bytecode : '0x' + bytecode
    const create3 = new ethers.Contract(CREATE3_DEPLOYER, CREATE3_ABI, this.wallet)
    console.log('  Deploying via CREATE3...')
    const tx = await create3.deploy(creationCode, portalSalt)
    const receipt = await tx.wait()
    const finalCode = await this.provider.getCode(predictedAddr)
    if (finalCode === '0x') throw new Error(`Base Portal deployment failed after tx ${receipt.hash}`)
    console.log(`  Deployed at: ${predictedAddr} (tx: ${receipt.hash})`)
    return predictedAddr
  }

  async predictLZProverAddress(lzSalt: string): Promise<string> {
    const create3 = new ethers.Contract(CREATE3_DEPLOYER, CREATE3_ABI, this.provider)
    return await create3.deployedAddress('0x', this.wallet.address, lzSalt)
  }
}

// ─── TronDeployer ─────────────────────────────────────────────────────────────

class TronDeployer {
  tronWeb: TronWeb
  private privateKey: string
  private factoryBase58: string

  constructor(rpcUrl: string, privateKey: string, factoryBase58: string) {
    this.privateKey = privateKey
    this.factoryBase58 = factoryBase58
    this.tronWeb = new TronWeb({ fullHost: rpcUrl, privateKey })
  }

  get address(): string { return (this.tronWeb.address.fromPrivateKey(this.privateKey) as string) || '' }

  get factory20hex(): string { return tronAddrToHex20(this.tronWeb, this.factoryBase58) }

  getChainId(): number {
    const host = (this.tronWeb as any).fullNode?.host || ''
    if (host.includes('api.trongrid.io') && !host.includes('shasta') && !host.includes('nile')) return TRON_MAINNET_CHAIN_ID
    if (host.includes('shasta')) return TRON_SHASTA_CHAIN_ID
    return TRON_NILE_CHAIN_ID
  }

  computeLZProver(
    lzSalt: string,
    endpointHex20: string,
    delegateHex20: string,
    portalHex20: string,
    crossVmProvers: string[],
  ): { initCode: string; addr20hex: string } {
    const abiCoder = ethers.AbiCoder.defaultAbiCoder()
    const { bytecode } = loadArtifact('LayerZeroProver')
    const creationCode = bytecode.startsWith('0x') ? bytecode : '0x' + bytecode
    const constructorArgs = abiCoder.encode(
      ['address', 'address', 'address', 'bytes32[]', 'uint256'],
      [endpointHex20, delegateHex20, portalHex20, crossVmProvers, MIN_GAS_LIMIT],
    )
    const initCode = ethers.hexlify(ethers.concat([ethers.getBytes(creationCode), ethers.getBytes(constructorArgs)]))
    const bytecodeHash = ethers.keccak256(initCode)
    const addr20hex = predictCreate2Tron(this.factory20hex, lzSalt, bytecodeHash)
    return { initCode, addr20hex }
  }

  private async deployViaFactory(initCode: string, salt: string): Promise<string> {
    const initCodeHex = initCode.startsWith('0x') ? initCode : '0x' + initCode
    const result = await this.tronWeb.transactionBuilder.triggerSmartContract(
      this.factoryBase58,
      'deploy(bytes,bytes32)',
      { feeLimit: 5_000_000_000, callValue: 0 },
      [{ type: 'bytes', value: initCodeHex }, { type: 'bytes32', value: salt }],
    )
    const signed = await this.tronWeb.trx.sign(result.transaction)
    const broadcast = await this.tronWeb.trx.sendRawTransaction(signed)
    if (!broadcast.result) throw new Error(`Factory deploy failed: ${JSON.stringify(broadcast)}`)
    console.log(`  txId: ${broadcast.txid}`)
    for (let i = 0; i < 30; i++) {
      await sleep(2000)
      const info: any = await this.tronWeb.trx.getTransactionInfo(broadcast.txid)
      if (info?.id) {
        for (const log of info.log || []) {
          if (log.topics?.[0] === DEPLOYED_TOPIC.slice(2)) {
            const addrHex20 = '0x' + log.topics[1].slice(-40).toLowerCase()
            console.log(`  Deployed at (hex20): ${addrHex20}`)
            return addrHex20
          }
        }
        throw new Error('No Deployed event found in receipt')
      }
    }
    throw new Error('Factory call timed out')
  }

  async deployPortal(existingPortal?: string): Promise<string> {
    if (existingPortal) {
      const hex20 = tronAddrToHex20(this.tronWeb, existingPortal)
      console.log(`  Using existing Tron Portal: ${existingPortal} (hex20: ${hex20})`)
      return hex20
    }
    const { abi, bytecode } = loadArtifact('Portal')
    const bytecodeHex = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode
    console.log('  Deploying directly via createSmartContract...')
    const deployerHex = this.tronWeb.defaultAddress.hex as string
    const tx = await this.tronWeb.transactionBuilder.createSmartContract(
      { abi, bytecode: bytecodeHex, feeLimit: 5_000_000_000, callValue: 0, userFeePercentage: 100, originEnergyLimit: 10_000_000 },
      deployerHex,
    )
    const signed = await this.tronWeb.trx.sign(tx)
    const broadcast = await this.tronWeb.trx.sendRawTransaction(signed)
    if (!broadcast.result) throw new Error(`Portal broadcast failed: ${JSON.stringify(broadcast)}`)
    console.log(`  txId: ${broadcast.txid}`)
    for (let i = 0; i < 20; i++) {
      await sleep(3000)
      const info: any = await this.tronWeb.trx.getTransactionInfo(broadcast.txid)
      if (info?.id) {
        if (info.receipt?.result !== 'SUCCESS') throw new Error(`Portal deployment failed: ${JSON.stringify(info)}`)
        const hex20 = '0x' + (info.contract_address as string).slice(2)
        console.log(`  Deployed at (hex20): ${hex20}`)
        return hex20
      }
    }
    throw new Error('Portal deployment timed out')
  }

  async deployLZProver(
    lzSalt: string,
    endpointHex20: string,
    delegateHex20: string,
    portalHex20: string,
    crossVmProvers: string[],
    predictedAddr20: string,
  ): Promise<string> {
    console.log(`  Predicted address: ${predictedAddr20}`)
    const base58 = this.tronWeb.address.fromHex('41' + predictedAddr20.slice(2)) as string
    const existing = await this.tronWeb.trx.getContract(base58).catch(() => null)
    if (existing?.contract_address) {
      console.log(`  Already deployed at: ${predictedAddr20}`)
      return predictedAddr20
    }
    const { initCode } = this.computeLZProver(lzSalt, endpointHex20, delegateHex20, portalHex20, crossVmProvers)
    const actual20 = await this.deployViaFactory(initCode, lzSalt)
    if (actual20.toLowerCase() !== predictedAddr20.toLowerCase()) {
      throw new Error(`Tron LZProver address mismatch! Expected: ${predictedAddr20}, Got: ${actual20}`)
    }
    return actual20
  }
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const isDryRun = process.argv.includes('--dry-run')
  const isTestnet = process.argv.includes('--testnet')
  const abiCoder = ethers.AbiCoder.defaultAbiCoder()

  let privateKey = process.env.PRIVATE_KEY || ''
  if (privateKey.startsWith('0x')) privateKey = privateKey.slice(2)
  if (!privateKey && !isDryRun) throw new Error('PRIVATE_KEY env var required')
  if (!privateKey) privateKey = '0'.repeat(64)

  const baseRpcUrl = process.env.BASE_RPC_URL || (isTestnet ? 'https://sepolia.base.org' : '')
  if (!baseRpcUrl) throw new Error('BASE_RPC_URL required (or use --testnet)')
  const tronRpcUrl = process.env.TRON_RPC_URL || (isTestnet ? 'https://api.shasta.trongrid.io' : '')
  if (!tronRpcUrl) throw new Error('TRON_RPC_URL required (or use --testnet)')
  const tronFactory = process.env.TRON_CREATE2_FACTORY || (isTestnet ? TRON_SHASTA_CREATE2_FACTORY : '')
  if (!tronFactory) throw new Error('TRON_CREATE2_FACTORY required')

  const rootSalt = ethers.id(process.env.SALT || 'eco-routes-v1')
  const portalSalt = ethers.keccak256(abiCoder.encode(['bytes32', 'bytes32'], [rootSalt, ethers.id('PORTAL')]))
  const lzSalt    = ethers.keccak256(abiCoder.encode(['bytes32', 'bytes32'], [rootSalt, ethers.id('LAYERZERO_PROVER')]))

  const baseDeployer = new BaseDeployer(baseRpcUrl, '0x' + privateKey)
  const tronDeployer = new TronDeployer(tronRpcUrl, privateKey, tronFactory)

  const baseLZEndpoint = process.env.BASE_LZ_ENDPOINT || ''
  const baseDelegate   = process.env.BASE_LZ_DELEGATE || baseDeployer.address

  const tronEndpointRaw  = process.env.TRON_LZ_ENDPOINT || ''
  const tronDelegateRaw  = process.env.TRON_LZ_DELEGATE || tronDeployer.address
  const tronLZEndpointHex20 = tronEndpointRaw ? tronAddrToHex20(tronDeployer.tronWeb, tronEndpointRaw) : ''
  const tronDelegateHex20   = tronDelegateRaw ? tronAddrToHex20(tronDeployer.tronWeb, tronDelegateRaw) : ''

  const existingBasePortal = process.env.BASE_PORTAL_CONTRACT
  const existingTronPortal = process.env.TRON_PORTAL_CONTRACT

  console.log('=== Phase 1: Portals + Tron LayerZeroProver ===')
  console.log(`Mode:    ${isDryRun ? 'DRY RUN' : 'LIVE'}`)
  console.log(`Network: ${isTestnet ? 'testnet' : 'mainnet'}`)
  console.log(`Salt:    ${process.env.SALT || 'eco-routes-v1'} → portalSalt=${portalSalt.slice(0,10)}... lzSalt=${lzSalt.slice(0,10)}...`)
  console.log()

  // ── Step 1: Base Portal ──────────────────────────────────────────────────
  console.log('=== Step 1: Portal on Base ===')
  let basePortal: string
  if (isDryRun) {
    basePortal = await baseDeployer.predictPortalAddress(portalSalt)
    console.log(`  [DRY RUN] Would deploy at: ${basePortal}`)
  } else {
    basePortal = await baseDeployer.deployPortal(portalSalt, existingBasePortal)
  }

  // ── Step 2: Tron Portal ──────────────────────────────────────────────────
  console.log('\n=== Step 2: Portal on Tron ===')
  let tronPortalHex20: string
  if (isDryRun) {
    console.log('  [DRY RUN] Address only known after deployment')
    tronPortalHex20 = '0x0000000000000000000000000000000000000000'
  } else {
    tronPortalHex20 = await tronDeployer.deployPortal(existingTronPortal)
  }

  // ── Step 3: Predict Base LZ Prover (no deployment) ───────────────────────
  console.log('\n=== Step 3: Predict Base LayerZeroProver address (no deployment) ===')
  const baseLZProverAddr = await baseDeployer.predictLZProverAddress(lzSalt)
  console.log(`  Base LayerZeroProver (CREATE3, predicted): ${baseLZProverAddr}`)
  if (!baseLZEndpoint) {
    console.log('  Note: BASE_LZ_ENDPOINT not set — this address is still valid for whitelist use')
  }

  // ── Step 4: Deploy Tron LayerZeroProver ──────────────────────────────────
  console.log('\n=== Step 4: Deploy Tron LayerZeroProver ===')
  if (!tronLZEndpointHex20) throw new Error('TRON_LZ_ENDPOINT required')

  // Whitelist entry for the Base LZ Prover — RIGHT-aligned bytes32.
  // Tron is EVM-compatible: origin.sender = bytes32(uint160(addr)) = right-aligned.
  // Using left-aligned causes LZ_PathNotInitializable() on proof delivery.
  const baseLZProverBytes32 = ethers.zeroPadValue(baseLZProverAddr, 32)
  console.log(`  Base LZ Prover → right-aligned bytes32: ${baseLZProverBytes32}`)

  const { addr20hex: tronLZProverPredicted } = tronDeployer.computeLZProver(
    lzSalt, tronLZEndpointHex20, tronDelegateHex20, tronPortalHex20, [baseLZProverBytes32],
  )

  let tronLZProverAddr: string
  if (isDryRun) {
    console.log(`  [DRY RUN] Would deploy at: ${tronLZProverPredicted}`)
    tronLZProverAddr = tronLZProverPredicted
  } else {
    tronLZProverAddr = await tronDeployer.deployLZProver(
      lzSalt, tronLZEndpointHex20, tronDelegateHex20, tronPortalHex20, [baseLZProverBytes32], tronLZProverPredicted,
    )
  }

  // ── Summary ───────────────────────────────────────────────────────────────
  const toB58 = (hex20: string) => tronDeployer.tronWeb.address.fromHex('41' + hex20.slice(2)) as string

  console.log('\n=== Phase 1 Complete ===')
  console.log(`  Base Portal:                  ${basePortal}`)
  console.log(`  Tron Portal (b58):            ${toB58(tronPortalHex20)}`)
  console.log(`  Tron Portal (hex20):          ${tronPortalHex20}`)
  console.log(`  Tron LZ Prover (b58):         ${toB58(tronLZProverAddr)}`)
  console.log(`  Tron LZ Prover (hex20):       ${tronLZProverAddr}`)
  console.log()
  console.log('  Base LZ Prover (predicted, NOT deployed yet):')
  console.log(`    ${baseLZProverAddr}`)
  console.log()
  console.log('  Next: run deploy-base-lz-prover.ts with:')
  console.log(`    TRON_LZ_PROVER=${tronLZProverAddr}`)
  console.log(`    BASE_PORTAL=${basePortal}`)
  console.log(`    SALT=${process.env.SALT || 'eco-routes-v1'}`)
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
