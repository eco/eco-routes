/**
 * deploy-base-tron.ts
 *
 * Mainnet deployer: Portal + LayerZeroProver to any combination of
 * Arbitrum, Base, Optimism, Polygon, Ethereum + Tron.
 *
 * Solves the chicken-and-egg problem:
 *  - CREATE3 on EVM chains → address is salt+deployer only (bytecode-independent)
 *  - Tron CREATE2 address predicted offline before deployment
 *
 * Required env vars:
 *   PRIVATE_KEY                 secp256k1 private key
 *   {CHAIN}_RPC_URL             per chain: ARBITRUM_RPC_URL, BASE_RPC_URL,
 *                               OPTIMISM_RPC_URL, POLYGON_RPC_URL, MAINNET_RPC_URL
 *   TRON_MAINNET_RPC_URL        Tron full-node RPC
 *   TRON_LAYERZERO_ENDPOINT     LayerZero endpoint address on Tron (base58 or hex)
 *   SALT                        salt string (or bytes32 hex)
 *
 * Skip-deployment env vars (if set, contract is reused):
 *   PORTAL_CONTRACT             existing Portal address (same on all EVM chains via CREATE3)
 *   TRON_PORTAL_CONTRACT        existing Tron Portal address
 *   TRON_LZ_PROVER              existing Tron LayerZeroProver address
 *
 * Optional env vars:
 *   LAYERZERO_ENDPOINT          LZ V2 endpoint on EVM chains
 *                               (default: 0x1a44076050125825900e736c501f859c50fE728c)
 *   LAYERZERO_DELEGATE          LZ delegate on EVM chains (default: deployer address)
 *   TRON_LZ_DELEGATE            LZ delegate on Tron (default: deployer address)
 *   TRON_CREATE2_FACTORY        Create2Factory_Tron address (default: mainnet factory)
 *   EVM_CREATE3_DEPLOYER        CREATE3 factory on EVM chains (default: 0xC6BAd...)
 *
 * Usage:
 *   # Dry run (predictions only, no transactions)
 *   npx ts-node scripts/deploy-base-tron.ts --chains base,arbitrum --dry-run
 *
 *   # Live mainnet deployment
 *   npx ts-node scripts/deploy-base-tron.ts --chains base,arbitrum,optimism,polygon,mainnet
 */

import { TronWeb } from 'tronweb'
import { ethers } from 'ethers'
import fs from 'fs'
import path from 'path'
import 'dotenv/config'

// ─── Chain registry ───────────────────────────────────────────────────────────

interface ChainDefinition {
  name: string
  lzEid: number
  rpcEnvVar: string
  isTestnet?: boolean
}

const CHAIN_REGISTRY: Record<string, ChainDefinition> = {
  // ── Mainnets ──────────────────────────────────────────────────────────────
  mainnet: {
    name: 'Ethereum Mainnet',
    lzEid: 30101,
    rpcEnvVar: 'MAINNET_RPC_URL',
  },
  arbitrum: {
    name: 'Arbitrum One',
    lzEid: 30110,
    rpcEnvVar: 'ARBITRUM_RPC_URL',
  },
  base: {
    name: 'Base',
    lzEid: 30184,
    rpcEnvVar: 'BASE_RPC_URL',
  },
  optimism: {
    name: 'Optimism',
    lzEid: 30111,
    rpcEnvVar: 'OPTIMISM_RPC_URL',
  },
  polygon: {
    name: 'Polygon',
    lzEid: 30109,
    rpcEnvVar: 'POLYGON_RPC_URL',
  },
  // ── Testnets ──────────────────────────────────────────────────────────────
  sepolia: {
    name: 'Ethereum Sepolia',
    lzEid: 40161,
    rpcEnvVar: 'SEPOLIA_RPC_URL',
    isTestnet: true,
  },
  'arbitrum-sepolia': {
    name: 'Arbitrum Sepolia',
    lzEid: 40231,
    rpcEnvVar: 'ARBITRUM_SEPOLIA_RPC_URL',
    isTestnet: true,
  },
  'base-sepolia': {
    name: 'Base Sepolia',
    lzEid: 40245,
    rpcEnvVar: 'BASE_SEPOLIA_RPC_URL',
    isTestnet: true,
  },
  'optimism-sepolia': {
    name: 'Optimism Sepolia',
    lzEid: 40232,
    rpcEnvVar: 'OPTIMISM_SEPOLIA_RPC_URL',
    isTestnet: true,
  },
  'polygon-amoy': {
    name: 'Polygon Amoy',
    lzEid: 40267,
    rpcEnvVar: 'POLYGON_AMOY_RPC_URL',
    isTestnet: true,
  },
}

const TRON_MAINNET_EID = 30420
const TRON_SHASTA_EID = 40420

/** Create2Factory_Tron on Tron Shasta testnet */
const TRON_SHASTA_CREATE2_FACTORY = 'TSh1WRYebthHLcfJ7eFqTyps97jMgbh96g'

// ─── Constants ────────────────────────────────────────────────────────────────

/** LZ V2 endpoint — same address on all supported EVM chains */
const DEFAULT_EVM_LZ_ENDPOINT = '0x1a44076050125825900e736c501f859c50fE728c'

/** CREATE3 deployer on EVM chains */
const DEFAULT_CREATE3_DEPLOYER = '0xC6BAd1EbAF366288dA6FB5689119eDd695a66814'

/** Create2Factory_Tron on Tron mainnet */
const TRON_MAINNET_CREATE2_FACTORY = 'TBA' // TODO: fill in mainnet factory address

const MIN_GAS_LIMIT = 200_000

/** keccak256("Deployed(address,bytes32)") — topic0 of Create2Factory_Tron event */
const DEPLOYED_TOPIC = ethers.id('Deployed(address,bytes32)')

const CREATE3_ABI = [
  'function deploy(bytes memory bytecode, bytes32 salt) external payable returns (address deployedAddress_)',
  'function deployedAddress(bytes memory bytecode, address sender, bytes32 salt) external view returns (address)',
]

// ─── Per-chain runtime config ─────────────────────────────────────────────────

interface EvmChainConfig {
  key: string
  name: string
  lzEid: number
  rpcUrl: string
  lzEndpoint: string
  delegate: string
  create3Deployer: string
}

// ─── Utilities ────────────────────────────────────────────────────────────────

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function loadArtifact(contractName: string): { abi: any[]; bytecode: string } {
  const artifactPath = path.join(
    __dirname,
    '..',
    'out',
    `${contractName}.sol`,
    `${contractName}.json`,
  )
  if (!fs.existsSync(artifactPath)) {
    throw new Error(
      `Artifact not found: ${artifactPath}. Run \`forge build\` first.`,
    )
  }
  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'))
  const bytecode =
    typeof artifact.bytecode === 'object'
      ? artifact.bytecode.object
      : artifact.bytecode
  return { abi: artifact.abi, bytecode }
}

function predictCreate2Tron(
  factory20hex: string,
  salt: string,
  bytecodeHash: string,
): string {
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

// ─── EvmDeployer ──────────────────────────────────────────────────────────────

class EvmDeployer {
  private provider: ethers.JsonRpcProvider
  private wallet: ethers.Wallet
  private abiCoder: ethers.AbiCoder
  readonly cfg: EvmChainConfig

  constructor(cfg: EvmChainConfig, privateKey: string) {
    this.cfg = cfg
    this.provider = new ethers.JsonRpcProvider(cfg.rpcUrl)
    this.wallet = new ethers.Wallet(privateKey, this.provider)
    this.abiCoder = ethers.AbiCoder.defaultAbiCoder()
  }

  get address(): string {
    return this.wallet.address
  }

  private tag(): string {
    return `[${this.cfg.name}]`
  }

  /** Predict Portal address via CREATE3 (view call, no tx) */
  async predictPortalAddress(portalSalt: string): Promise<string> {
    const create3 = new ethers.Contract(
      this.cfg.create3Deployer,
      CREATE3_ABI,
      this.provider,
    )
    return await create3.deployedAddress('0x', this.wallet.address, portalSalt)
  }

  async deployPortal(
    portalSalt: string,
    existingPortal?: string,
  ): Promise<string> {
    if (existingPortal) {
      console.log(`  ${this.tag()} Using existing Portal: ${existingPortal}`)
      return existingPortal
    }

    const predicted = await this.predictPortalAddress(portalSalt)
    console.log(`  ${this.tag()} Predicted Portal: ${predicted}`)

    const code = await this.provider.getCode(predicted)
    if (code !== '0x') {
      console.log(`  ${this.tag()} Portal already deployed`)
      return predicted
    }

    const { bytecode } = loadArtifact('Portal')
    const creationCode = bytecode.startsWith('0x') ? bytecode : '0x' + bytecode
    const create3 = new ethers.Contract(
      this.cfg.create3Deployer,
      CREATE3_ABI,
      this.wallet,
    )
    console.log(`  ${this.tag()} Deploying Portal via CREATE3...`)
    const tx = await create3.deploy(creationCode, portalSalt)
    const receipt = await tx.wait()

    const finalCode = await this.provider.getCode(predicted)
    if (finalCode === '0x') {
      throw new Error(
        `${this.tag()} Portal deploy failed: no code at ${predicted} (tx: ${receipt.hash})`,
      )
    }
    console.log(`  ${this.tag()} Portal deployed: ${predicted} (tx: ${receipt.hash})`)
    return predicted
  }

  /** Predict LZProver address via CREATE3 (bytecode-independent) */
  async predictLZProverAddress(lzSalt: string): Promise<string> {
    const create3 = new ethers.Contract(
      this.cfg.create3Deployer,
      CREATE3_ABI,
      this.provider,
    )
    return await create3.deployedAddress('0x', this.wallet.address, lzSalt)
  }

  async deployLZProver(
    lzSalt: string,
    portal: string,
    whitelist: string[],
    predicted: string,
  ): Promise<string> {
    console.log(`  ${this.tag()} Predicted LZProver: ${predicted}`)

    const code = await this.provider.getCode(predicted)
    if (code !== '0x') {
      console.log(`  ${this.tag()} LZProver already deployed`)
      return predicted
    }

    const { bytecode } = loadArtifact('LayerZeroProver')
    const creationCode = bytecode.startsWith('0x') ? bytecode : '0x' + bytecode
    const constructorArgs = this.abiCoder.encode(
      ['address', 'address', 'address', 'bytes32[]', 'uint256'],
      [
        this.cfg.lzEndpoint,
        this.cfg.delegate,
        portal,
        whitelist,
        MIN_GAS_LIMIT,
      ],
    )
    const initCode = ethers.concat([
      ethers.getBytes(creationCode),
      ethers.getBytes(constructorArgs),
    ])

    const create3 = new ethers.Contract(
      this.cfg.create3Deployer,
      CREATE3_ABI,
      this.wallet,
    )
    console.log(`  ${this.tag()} Deploying LZProver via CREATE3...`)
    const tx = await create3.deploy(initCode, lzSalt)
    const receipt = await tx.wait()

    const finalCode = await this.provider.getCode(predicted)
    if (finalCode === '0x') {
      throw new Error(`${this.tag()} LZProver deploy verification failed (tx: ${receipt.hash})`)
    }
    console.log(`  ${this.tag()} LZProver deployed: ${predicted} (tx: ${receipt.hash})`)
    return predicted
  }

  async verifyLZProverWhitelist(
    lzProver: string,
    tronProverBytes32: string,
    tronEid: number,
  ): Promise<void> {
    const WHITELIST_ABI = [
      'function getWhitelist() view returns (bytes32[])',
      'function isWhitelisted(bytes32 addr) view returns (bool)',
      'function allowInitializePath(tuple(uint32 srcEid, bytes32 sender, uint64 nonce) origin) view returns (bool)',
    ]
    const contract = new ethers.Contract(lzProver, WHITELIST_ABI, this.provider)

    const whitelist: string[] = await contract.getWhitelist()
    const isWL: boolean = await contract.isWhitelisted(tronProverBytes32)
    const allowInit: boolean = await contract.allowInitializePath({
      srcEid: tronEid,
      sender: tronProverBytes32,
      nonce: 0,
    })

    console.log(`  ${this.tag()} whitelist:              ${JSON.stringify(whitelist)}`)
    console.log(`  ${this.tag()} isWhitelisted(tron):    ${isWL}`)
    console.log(`  ${this.tag()} allowInitializePath:    ${allowInit}`)

    if (!isWL || !allowInit) {
      throw new Error(
        `${this.tag()} LZProver whitelist invalid!\n` +
          `  Expected Tron prover: ${tronProverBytes32}\n` +
          `  Got: ${JSON.stringify(whitelist)}\n` +
          `  isWhitelisted=${isWL}, allowInitializePath=${allowInit}`,
      )
    }
    console.log(`  ${this.tag()} ✓ Whitelist OK`)
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

  get address(): string {
    return (this.tronWeb.address.fromPrivateKey(this.privateKey) as string) || ''
  }

  /** Factory address as 0x-prefixed 20-byte hex */
  get factory20hex(): string {
    return tronAddrToHex20(this.tronWeb, this.factoryBase58)
  }

  /** Build LZ Prover init code and predict Tron CREATE2 address */
  computeLZProver(
    lzSalt: string,
    endpointHex20: string,
    delegateHex20: string,
    portalHex20: string,
    whitelist: string[],
  ): { initCode: string; addr20hex: string } {
    const abiCoder = ethers.AbiCoder.defaultAbiCoder()
    const { bytecode } = loadArtifact('LayerZeroProver')
    const creationCode = bytecode.startsWith('0x') ? bytecode : '0x' + bytecode
    const constructorArgs = abiCoder.encode(
      ['address', 'address', 'address', 'bytes32[]', 'uint256'],
      [endpointHex20, delegateHex20, portalHex20, whitelist, MIN_GAS_LIMIT],
    )
    const initCode = ethers.hexlify(
      ethers.concat([
        ethers.getBytes(creationCode),
        ethers.getBytes(constructorArgs),
      ]),
    )
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
      [
        { type: 'bytes', value: initCodeHex },
        { type: 'bytes32', value: salt },
      ],
    )

    const signed = await this.tronWeb.trx.sign(result.transaction)
    const broadcast = await this.tronWeb.trx.sendRawTransaction(signed)
    if (!broadcast.result) {
      throw new Error(`[Tron] Factory deploy failed: ${JSON.stringify(broadcast)}`)
    }
    console.log(`  [Tron] txId: ${broadcast.txid}`)

    for (let i = 0; i < 30; i++) {
      await sleep(2000)
      const info: any = await this.tronWeb.trx.getTransactionInfo(broadcast.txid)
      if (info?.id) {
        const logs: any[] = info.log || []
        for (const log of logs) {
          if (log.topics?.[0] === DEPLOYED_TOPIC.slice(2)) {
            const addr = '0x' + log.topics[1].slice(-40).toLowerCase()
            console.log(`  [Tron] Deployed at (hex20): ${addr}`)
            return addr
          }
        }
        throw new Error('[Tron] No Deployed event in receipt')
      }
    }
    throw new Error('[Tron] Factory call timed out')
  }

  /**
   * Deploy Portal on Tron directly.
   * TVM does not support nested CREATE inside CREATE2, so Portal must be
   * deployed with a standard createSmartContract call.
   */
  async deployPortal(existingPortal?: string): Promise<string> {
    if (existingPortal) {
      const hex20 = tronAddrToHex20(this.tronWeb, existingPortal)
      console.log(`  [Tron] Using existing Portal: ${existingPortal} (hex20: ${hex20})`)
      return hex20
    }

    const { abi, bytecode } = loadArtifact('PortalTron')
    const bytecodeHex = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode

    console.log('  [Tron] Deploying PortalTron via createSmartContract...')
    const deployerHex = this.tronWeb.defaultAddress.hex as string
    const tx = await this.tronWeb.transactionBuilder.createSmartContract(
      {
        abi,
        bytecode: bytecodeHex,
        feeLimit: 5_000_000_000,
        callValue: 0,
        userFeePercentage: 100,
        originEnergyLimit: 10_000_000,
      },
      deployerHex,
    )

    const signed = await this.tronWeb.trx.sign(tx)
    const broadcast = await this.tronWeb.trx.sendRawTransaction(signed)
    if (!broadcast.result) {
      throw new Error(`[Tron] Portal broadcast failed: ${JSON.stringify(broadcast)}`)
    }
    console.log(`  [Tron] txId: ${broadcast.txid}`)

    for (let i = 0; i < 20; i++) {
      await sleep(3000)
      const info: any = await this.tronWeb.trx.getTransactionInfo(broadcast.txid)
      if (info?.id) {
        if (info.receipt?.result !== 'SUCCESS') {
          throw new Error(`[Tron] Portal deployment failed: ${JSON.stringify(info)}`)
        }
        const hex20 = '0x' + (info.contract_address as string).slice(2)
        console.log(`  [Tron] Portal deployed (hex20): ${hex20}`)
        return hex20
      }
    }
    throw new Error('[Tron] Portal deployment timed out')
  }

  async deployLZProver(
    lzSalt: string,
    endpointHex20: string,
    delegateHex20: string,
    portalHex20: string,
    whitelist: string[],
    predicted: string,
    existingProver?: string,
  ): Promise<string> {
    if (existingProver) {
      const hex20 = tronAddrToHex20(this.tronWeb, existingProver)
      console.log(`  [Tron] Using existing LZProver: ${existingProver} (hex20: ${hex20})`)
      return hex20
    }

    console.log(`  [Tron] Predicted LZProver: ${predicted}`)

    const base58 = this.tronWeb.address.fromHex('41' + predicted.slice(2)) as string
    const existing = await this.tronWeb.trx.getContract(base58).catch(() => null)
    if (existing?.contract_address) {
      console.log(`  [Tron] LZProver already deployed`)
      return predicted
    }

    const { initCode } = this.computeLZProver(
      lzSalt,
      endpointHex20,
      delegateHex20,
      portalHex20,
      whitelist,
    )
    const deployed = await this.deployViaFactory(initCode, lzSalt)

    if (deployed.toLowerCase() !== predicted.toLowerCase()) {
      throw new Error(
        `[Tron] LZProver address mismatch! Expected: ${predicted}, Got: ${deployed}`,
      )
    }
    return deployed
  }

  async verifyLZProverWhitelist(
    tronLZProver: string,
    evmEntries: { name: string; bytes32: string; eid: number }[],
  ): Promise<void> {
    const tronProverB58 = this.tronWeb.address.fromHex(
      '41' + tronLZProver.slice(2),
    ) as string

    const TRON_WHITELIST_ABI = [
      {
        name: 'getWhitelist',
        type: 'function',
        inputs: [],
        outputs: [{ type: 'bytes32[]' }],
        stateMutability: 'view',
      },
      {
        name: 'isWhitelisted',
        type: 'function',
        inputs: [{ name: 'addr', type: 'bytes32' }],
        outputs: [{ type: 'bool' }],
        stateMutability: 'view',
      },
      {
        name: 'allowInitializePath',
        type: 'function',
        inputs: [
          {
            name: 'origin',
            type: 'tuple',
            components: [
              { name: 'srcEid', type: 'uint32' },
              { name: 'sender', type: 'bytes32' },
              { name: 'nonce', type: 'uint64' },
            ],
          },
        ],
        outputs: [{ type: 'bool' }],
        stateMutability: 'view',
      },
    ]
    const contract = await this.tronWeb.contract(TRON_WHITELIST_ABI, tronProverB58)

    for (const { name, bytes32, eid } of evmEntries) {
      const isWL: boolean = await contract.isWhitelisted(bytes32).call()
      const allowInit: boolean = await contract
        .allowInitializePath([eid, bytes32, 0])
        .call()
      console.log(
        `  [Tron] isWhitelisted(${name}): ${isWL}, allowInitializePath(eid=${eid}): ${allowInit}`,
      )
      if (!isWL || !allowInit) {
        throw new Error(
          `[Tron] Whitelist missing ${name}!\n` +
            `  Expected: ${bytes32}`,
        )
      }
    }
    console.log(`  [Tron] ✓ Whitelist OK`)
  }

  toBase58(hex20: string): string {
    return this.tronWeb.address.fromHex('41' + hex20.slice(2)) as string
  }
}

// ─── DeployOrchestrator ───────────────────────────────────────────────────────

class DeployOrchestrator {
  private evmDeployers: EvmDeployer[]
  private tronDeployer: TronDeployer
  private isDryRun: boolean
  private useTronShasta: boolean
  private tronEid: number
  private abiCoder: ethers.AbiCoder
  private tronLZEndpointHex20: string
  private tronDelegateHex20: string
  private existingTronPortal?: string
  private existingTronLZProver?: string
  private existingEvmPortal?: string
  private portalSalt: string
  private lzSalt: string

  constructor() {
    this.isDryRun = process.argv.includes('--dry-run')
    this.abiCoder = ethers.AbiCoder.defaultAbiCoder()

    // ── Parse --chains ──────────────────────────────────────────────────────
    const chainsIdx = process.argv.indexOf('--chains')
    const chainsVal =
      chainsIdx !== -1
        ? process.argv[chainsIdx + 1]
        : process.argv.find((a) => a.startsWith('--chains='))?.split('=')[1]

    if (!chainsVal || chainsVal.startsWith('--')) {
      throw new Error(
        `--chains required. Supported: ${Object.keys(CHAIN_REGISTRY).join(', ')}\n` +
          `Example: --chains base,arbitrum,optimism`,
      )
    }

    const chainKeys = chainsVal.split(',').map((s) => s.trim().toLowerCase())
    for (const key of chainKeys) {
      if (!CHAIN_REGISTRY[key]) {
        throw new Error(
          `Unknown chain '${key}'. Supported: ${Object.keys(CHAIN_REGISTRY).join(', ')}`,
        )
      }
    }

    // ── Private key ─────────────────────────────────────────────────────────
    let privateKey = process.env.PRIVATE_KEY || ''
    if (privateKey.startsWith('0x')) privateKey = privateKey.slice(2)
    if (!privateKey && !this.isDryRun) throw new Error('PRIVATE_KEY env var required')
    if (!privateKey) privateKey = '0'.repeat(64)

    // ── Salt — accepts both a plain string and a bytes32 hex ────────────────
    const saltInput = process.env.SALT || 'eco-routes-v1'
    const rootSalt = saltInput.startsWith('0x') ? saltInput : ethers.id(saltInput)
    this.portalSalt = ethers.keccak256(
      this.abiCoder.encode(
        ['bytes32', 'bytes32'],
        [rootSalt, ethers.id('PORTAL')],
      ),
    )
    this.lzSalt = ethers.keccak256(
      this.abiCoder.encode(
        ['bytes32', 'bytes32'],
        [rootSalt, ethers.id('LAYERZERO_PROVER')],
      ),
    )

    const create3Deployer =
      process.env.EVM_CREATE3_DEPLOYER || DEFAULT_CREATE3_DEPLOYER
    const evmLZEndpoint =
      process.env.LAYERZERO_ENDPOINT || DEFAULT_EVM_LZ_ENDPOINT

    // ── Build per-chain deployers ────────────────────────────────────────────
    this.evmDeployers = chainKeys.map((key) => {
      const def = CHAIN_REGISTRY[key]
      const rpcUrl = process.env[def.rpcEnvVar] || ''
      if (!rpcUrl)
        throw new Error(`${def.rpcEnvVar} required for chain '${key}'`)

      const cfg: EvmChainConfig = {
        key,
        name: def.name,
        lzEid: def.lzEid,
        rpcUrl,
        lzEndpoint: evmLZEndpoint,
        delegate: '', // filled after wallet is created
        create3Deployer,
      }
      const deployer = new EvmDeployer(cfg, '0x' + privateKey)
      cfg.delegate = process.env.LAYERZERO_DELEGATE || deployer.address
      return deployer
    })

    // ── Tron config — auto-select Shasta when all EVM chains are testnets ───
    const allTestnet = chainKeys.every((k) => CHAIN_REGISTRY[k].isTestnet)
    const useTronShasta = allTestnet

    const tronRpcUrl = useTronShasta
      ? process.env.TRON_SHASTA_RPC_URL || 'https://api.shasta.trongrid.io'
      : process.env.TRON_MAINNET_RPC_URL || ''
    if (!tronRpcUrl) throw new Error('TRON_MAINNET_RPC_URL required')

    const tronFactory =
      process.env.TRON_CREATE2_FACTORY ||
      (useTronShasta ? TRON_SHASTA_CREATE2_FACTORY : TRON_MAINNET_CREATE2_FACTORY)
    if (!tronFactory || tronFactory === 'TBA') {
      throw new Error(
        'TRON_CREATE2_FACTORY required (or set TRON_MAINNET_CREATE2_FACTORY in the script)',
      )
    }

    this.tronDeployer = new TronDeployer(tronRpcUrl, privateKey, tronFactory)

    const tronEndpointRaw = process.env.TRON_LAYERZERO_ENDPOINT || ''
    if (!tronEndpointRaw && !this.isDryRun) {
      throw new Error('TRON_LAYERZERO_ENDPOINT required')
    }
    const tronDelegateRaw =
      process.env.TRON_LZ_DELEGATE || this.tronDeployer.address

    this.tronLZEndpointHex20 = tronEndpointRaw
      ? tronAddrToHex20(this.tronDeployer.tronWeb, tronEndpointRaw)
      : '0x' + '00'.repeat(20)
    this.tronDelegateHex20 = tronDelegateRaw
      ? tronAddrToHex20(this.tronDeployer.tronWeb, tronDelegateRaw)
      : '0x' + '00'.repeat(20)

    // ── Skip-deployment env vars ─────────────────────────────────────────────
    this.existingEvmPortal = process.env.PORTAL_CONTRACT || undefined
    this.existingTronPortal = process.env.TRON_PORTAL_CONTRACT || undefined
    this.existingTronLZProver = process.env.TRON_LZ_PROVER || undefined
    this.tronEid = useTronShasta ? TRON_SHASTA_EID : TRON_MAINNET_EID
    this.useTronShasta = useTronShasta
  }

  async run(): Promise<void> {
    const chainNames = this.evmDeployers.map((d) => d.cfg.name).join(', ')
    console.log('=== EVM + Tron Deployment Orchestrator ===')
    console.log(`Mode:        ${this.isDryRun ? 'DRY RUN (no transactions)' : 'LIVE'}`)
    console.log(`EVM chains:  ${chainNames}`)
    console.log(`Tron:        ${this.useTronShasta ? 'Shasta (testnet)' : 'Mainnet'} (EID ${this.tronEid})`)
    console.log(`Portal salt: ${this.portalSalt}`)
    console.log(`LZ salt:     ${this.lzSalt}`)
    if (this.existingEvmPortal)
      console.log(`Reusing EVM Portal:      ${this.existingEvmPortal}`)
    if (this.existingTronPortal)
      console.log(`Reusing Tron Portal:     ${this.existingTronPortal}`)
    if (this.existingTronLZProver)
      console.log(`Reusing Tron LZProver:   ${this.existingTronLZProver}`)
    console.log()

    // ── Step 1: Deploy Portals on all EVM chains ──────────────────────────────
    console.log('=== Step 1: EVM Portals ===')
    const evmPortals: Record<string, string> = {}
    for (const deployer of this.evmDeployers) {
      if (this.isDryRun) {
        const addr = await deployer.predictPortalAddress(this.portalSalt)
        console.log(`  [${deployer.cfg.name}] [DRY RUN] Portal would be: ${addr}`)
        evmPortals[deployer.cfg.key] = addr
      } else {
        evmPortals[deployer.cfg.key] = await deployer.deployPortal(
          this.portalSalt,
          this.existingEvmPortal,
        )
      }
    }

    // ── Step 2: Deploy Portal on Tron ─────────────────────────────────────────
    console.log('\n=== Step 2: Tron Portal ===')
    let tronPortalHex20: string
    if (this.isDryRun) {
      console.log(
        '  [Tron] [DRY RUN] Address only known after deployment (direct deploy)',
      )
      tronPortalHex20 = '0x' + '00'.repeat(20)
    } else {
      tronPortalHex20 = await this.tronDeployer.deployPortal(
        this.existingTronPortal,
      )
    }

    // ── Step 3: Predict all EVM LZProver addresses (CREATE3, view-only) ───────
    console.log('\n=== Step 3: Predict EVM LZProver addresses ===')
    const evmLZProverAddrs: Record<string, string> = {}
    for (const deployer of this.evmDeployers) {
      const addr = await deployer.predictLZProverAddress(this.lzSalt)
      console.log(`  [${deployer.cfg.name}] LZProver: ${addr}`)
      evmLZProverAddrs[deployer.cfg.key] = addr
    }

    // ── Step 4: Compute Tron LZProver (whitelist = all EVM provers) ───────────
    console.log('\n=== Step 4: Construct Tron LZProver ===')

    // Each EVM prover is right-aligned to bytes32 (how LZ encodes origin.sender)
    const evmProverEntries = this.evmDeployers.map((d) => ({
      name: d.cfg.name,
      eid: d.cfg.lzEid,
      bytes32: ethers.zeroPadValue(evmLZProverAddrs[d.cfg.key], 32),
    }))

    for (const { name, bytes32 } of evmProverEntries) {
      console.log(`  [${name}] right-aligned bytes32: ${bytes32}`)
    }

    const tronWhitelist = evmProverEntries.map((e) => e.bytes32)
    const { addr20hex: tronLZProverPredicted } =
      this.tronDeployer.computeLZProver(
        this.lzSalt,
        this.tronLZEndpointHex20,
        this.tronDelegateHex20,
        tronPortalHex20,
        tronWhitelist,
      )
    console.log(`  [Tron] LZProver predicted: ${tronLZProverPredicted}`)

    // ── Step 5: Deploy Tron LZProver ─────────────────────────────────────────
    console.log('\n=== Step 5: Tron LZProver ===')
    let tronLZProverAddr: string
    if (this.isDryRun) {
      console.log(`  [Tron] [DRY RUN] Would deploy at: ${tronLZProverPredicted}`)
      tronLZProverAddr = tronLZProverPredicted
    } else {
      tronLZProverAddr = await this.tronDeployer.deployLZProver(
        this.lzSalt,
        this.tronLZEndpointHex20,
        this.tronDelegateHex20,
        tronPortalHex20,
        tronWhitelist,
        tronLZProverPredicted,
        this.existingTronLZProver,
      )
    }

    const tronLZProverBytes32 = ethers.zeroPadValue(tronLZProverAddr, 32)

    // ── Steps 6 + 7: For each chain — deploy EVM LZProver then verify both sides
    const evmLZProverFinals: Record<string, string> = {}

    for (const deployer of this.evmDeployers) {
      const selfBytes32 = ethers.zeroPadValue(
        evmLZProverAddrs[deployer.cfg.key],
        32,
      )
      // Whitelist: Tron prover + self (enables Tron→EVM proofs + local proving)
      const evmWhitelist = [tronLZProverBytes32, selfBytes32]

      console.log(`\n=== Step 6: [${deployer.cfg.name}] Deploy LZProver ===`)
      console.log(
        `  Tron prover (right-aligned): ${tronLZProverBytes32}`,
      )
      console.log(
        `  Self        (right-aligned): ${selfBytes32}`,
      )

      if (this.isDryRun) {
        console.log(
          `  [DRY RUN] Would deploy at: ${evmLZProverAddrs[deployer.cfg.key]}`,
        )
        evmLZProverFinals[deployer.cfg.key] =
          evmLZProverAddrs[deployer.cfg.key]
      } else {
        const deployed = await deployer.deployLZProver(
          this.lzSalt,
          evmPortals[deployer.cfg.key],
          evmWhitelist,
          evmLZProverAddrs[deployer.cfg.key],
        )
        if (deployed.toLowerCase() !== evmLZProverAddrs[deployer.cfg.key].toLowerCase()) {
          throw new Error(
            `[${deployer.cfg.name}] LZProver address mismatch! ` +
              `Expected: ${evmLZProverAddrs[deployer.cfg.key]}, Got: ${deployed}`,
          )
        }
        evmLZProverFinals[deployer.cfg.key] = deployed

        console.log(`\n=== Step 7: [${deployer.cfg.name}] Verify whitelists ===`)
        // EVM side: has Tron prover in whitelist?
        await deployer.verifyLZProverWhitelist(deployed, tronLZProverBytes32, this.tronEid)
        // Tron side: has this EVM prover in whitelist?
        await this.tronDeployer.verifyLZProverWhitelist(tronLZProverAddr, [
          {
            name: deployer.cfg.name,
            bytes32: ethers.zeroPadValue(deployed, 32),
            eid: deployer.cfg.lzEid,
          },
        ])
      }
    }

    // ── Summary ───────────────────────────────────────────────────────────────
    console.log('\n=== Deployment Summary ===')
    for (const deployer of this.evmDeployers) {
      const portal = evmPortals[deployer.cfg.key] ?? '(dry run)'
      const prover =
        evmLZProverFinals[deployer.cfg.key] ??
        evmLZProverAddrs[deployer.cfg.key]
      console.log(`  [${deployer.cfg.name}]`)
      console.log(`    Portal:   ${portal}`)
      console.log(`    LZProver: ${prover}`)
    }
    console.log(`  [Tron]`)
    console.log(
      `    Portal (b58):    ${this.tronDeployer.toBase58(tronPortalHex20)}`,
    )
    console.log(`    Portal (hex20):  ${tronPortalHex20}`)
    console.log(
      `    LZProver (b58):  ${this.tronDeployer.toBase58(tronLZProverAddr)}`,
    )
    console.log(`    LZProver (hex20): ${tronLZProverAddr}`)

    console.log('\n=== Whitelist Encodings (right-aligned bytes32) ===')
    console.log('  Tron LZProver whitelist contains:')
    for (const { name, bytes32 } of evmProverEntries) {
      console.log(`    [${name}]: ${bytes32}`)
    }
    console.log('  Each EVM LZProver whitelist contains:')
    console.log(`    Tron:  ${tronLZProverBytes32}`)
    console.log(`    Self:  <own address, right-aligned>`)
  }
}

// ─── Entry point ──────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const orchestrator = new DeployOrchestrator()
  await orchestrator.run()
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err)
    process.exitCode = 1
  })
}

export default DeployOrchestrator
