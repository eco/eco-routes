/**
 * deploy-base-tron.ts
 *
 * Orchestrates deterministic deployment of Portal + LayerZeroProver to both
 * Base (EVM via CREATE2/CREATE3) and Tron (via Create2Factory_Tron).
 *
 * Solves the chicken-and-egg problem by:
 *  - Using CREATE3 on Base (address independent of bytecode/constructor args)
 *  - Predicting the Tron CREATE2 address offline before any deployment
 *
 * Usage:
 *   # Dry run (predictions only, no transactions)
 *   SALT=test BASE_LZ_ENDPOINT=0x... TRON_LZ_ENDPOINT=T... \
 *     npx ts-node scripts/deploy-base-tron.ts --testnet --dry-run
 *
 *   # Full testnet deployment
 *   PRIVATE_KEY=... SALT=test BASE_LZ_ENDPOINT=0x... TRON_LZ_ENDPOINT=T... \
 *     npx ts-node scripts/deploy-base-tron.ts --testnet
 */

import { TronWeb } from 'tronweb'
import { ethers } from 'ethers'
import fs from 'fs'
import path from 'path'
import 'dotenv/config'

// ─── Constants ────────────────────────────────────────────────────────────────

/** ERC-2470 SingletonFactory — used for Portal deployment on Base */
const ERC2470_FACTORY = '0xce0042B868300000d44A59004Da54A005ffdcf9f'
/** CREATE3 deployer — used for LayerZeroProver deployment on Base */
const CREATE3_DEPLOYER = '0xC6BAd1EbAF366288dA6FB5689119eDd695a66814'
const MIN_GAS_LIMIT = 200_000

/** Default Create2Factory_Tron address on Shasta testnet */
const TRON_SHASTA_CREATE2_FACTORY = 'TSh1WRYebthHLcfJ7eFqTyps97jMgbh96g'

/** keccak256("Deployed(address,bytes32)") — topic0 of Create2Factory_Tron event */
const DEPLOYED_TOPIC = ethers.id('Deployed(address,bytes32)')

const TRON_MAINNET_CHAIN_ID = 728126428
const TRON_SHASTA_CHAIN_ID = 2494104990
const TRON_NILE_CHAIN_ID = 3448148188

const ERC2470_ABI = [
  'function deploy(bytes calldata _initCode, bytes32 _salt) returns (address payable createdContract)',
]

const CREATE3_ABI = [
  'function deploy(bytes memory bytecode, bytes32 salt) external payable returns (address deployedAddress_)',
  'function deployedAddress(bytes memory bytecode, address sender, bytes32 salt) external view returns (address)',
]

// ─── Utility functions ────────────────────────────────────────────────────────

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms))
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

/**
 * Predict CREATE2 address on Tron using the 0x41 prefix formula.
 * @param factory20hex  20-byte hex address of the factory (0x-prefixed, 40 hex chars)
 * @param salt          0x-prefixed bytes32
 * @param bytecodeHash  keccak256 of init code, 0x-prefixed bytes32
 */
function predictCreate2Tron(
  factory20hex: string,
  salt: string,
  bytecodeHash: string,
): string {
  const packed = ethers.concat([
    new Uint8Array([0x41]),
    ethers.getBytes(factory20hex), // 20 bytes
    ethers.getBytes(salt), // 32 bytes
    ethers.getBytes(bytecodeHash), // 32 bytes
  ])
  return '0x' + ethers.keccak256(packed).slice(-40)
}

/**
 * Left-align an EVM address in bytes32 — equivalent to bytes32(bytes20(addr)) in Solidity.
 * Result: 0x + 40 hex chars (address) + 24 zero chars = 66 chars total.
 */
function addressToBytes32Left(addr: string): string {
  const stripped = (addr.startsWith('0x') ? addr.slice(2) : addr).toLowerCase()
  return '0x' + stripped + '000000000000000000000000'
}

/**
 * Normalize a Tron address (base58 / hex41 / hex0x) to 0x-prefixed 20-byte hex.
 */
function tronAddrToHex20(tronWeb: TronWeb, addr: string): string {
  if (!addr) return ''
  if (addr.startsWith('0x')) return addr.toLowerCase()
  if (addr.startsWith('41')) return ('0x' + addr.slice(2)).toLowerCase()
  // base58
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

  get address(): string {
    return this.wallet.address
  }

  async getChainId(): Promise<bigint> {
    const network = await this.provider.getNetwork()
    return network.chainId
  }

  /** Predict Portal address via CREATE3 (view call) */
  async predictPortalAddress(portalSalt: string): Promise<string> {
    const create3 = new ethers.Contract(CREATE3_DEPLOYER, CREATE3_ABI, this.provider)
    return await create3.deployedAddress('0x', this.wallet.address, portalSalt)
  }

  /** Deploy Portal on Base via CREATE3 */
  async deployPortal(
    portalSalt: string,
    existingPortal?: string,
  ): Promise<string> {
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
    if (finalCode === '0x') {
      throw new Error(
        `Base Portal deployment failed: no code at ${predictedAddr} after tx ${receipt.hash}`,
      )
    }
    console.log(`  Deployed at: ${predictedAddr} (tx: ${receipt.hash})`)
    return predictedAddr
  }

  /**
   * Predict Base LayerZeroProver address via CREATE3.
   * This is a view call — no transaction required.
   */
  async predictLZProverAddress(lzSalt: string): Promise<string> {
    const create3 = new ethers.Contract(
      CREATE3_DEPLOYER,
      CREATE3_ABI,
      this.provider,
    )
    // Bytecode param is ignored for CREATE3 address computation
    return await create3.deployedAddress('0x', this.wallet.address, lzSalt)
  }

  /** Deploy Base LayerZeroProver via CREATE3 */
  async deployLZProver(
    lzSalt: string,
    endpoint: string,
    delegate: string,
    portal: string,
    crossVmProvers: string[],
    predictedAddr: string,
  ): Promise<string> {
    console.log(`  Predicted address: ${predictedAddr}`)

    const code = await this.provider.getCode(predictedAddr)
    if (code !== '0x') {
      console.log(`  Already deployed at: ${predictedAddr}`)
      return predictedAddr
    }

    const { bytecode } = loadArtifact('LayerZeroProver')
    const creationCode = bytecode.startsWith('0x') ? bytecode : '0x' + bytecode
    const constructorArgs = this.abiCoder.encode(
      ['address', 'address', 'address', 'bytes32[]', 'uint256'],
      [endpoint, delegate, portal, crossVmProvers, MIN_GAS_LIMIT],
    )
    const initCode = ethers.concat([
      ethers.getBytes(creationCode),
      ethers.getBytes(constructorArgs),
    ])

    const create3 = new ethers.Contract(
      CREATE3_DEPLOYER,
      CREATE3_ABI,
      this.wallet,
    )
    console.log('  Deploying via CREATE3...')
    const tx = await create3.deploy(initCode, lzSalt)
    const receipt = await tx.wait()

    const finalCode = await this.provider.getCode(predictedAddr)
    if (finalCode === '0x') {
      throw new Error('Base LayerZeroProver deployment verification failed')
    }
    console.log(`  Deployed at: ${predictedAddr} (tx: ${receipt.hash})`)
    return predictedAddr
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

  /** Factory address as 0x-prefixed 20-byte hex (strips the 0x41 Tron prefix) */
  get factory20hex(): string {
    return tronAddrToHex20(this.tronWeb, this.factoryBase58)
  }

  getChainId(): number {
    const host = (this.tronWeb as any).fullNode?.host || ''
    if (
      host.includes('api.trongrid.io') &&
      !host.includes('shasta') &&
      !host.includes('nile')
    )
      return TRON_MAINNET_CHAIN_ID
    if (host.includes('shasta')) return TRON_SHASTA_CHAIN_ID
    return TRON_NILE_CHAIN_ID
  }

  /** Offline prediction of Portal address on Tron */
  predictPortalAddress(portalSalt: string): string {
    const { bytecode } = loadArtifact('Portal')
    const creationCode = bytecode.startsWith('0x') ? bytecode : '0x' + bytecode
    const bytecodeHash = ethers.keccak256(creationCode)
    return predictCreate2Tron(this.factory20hex, portalSalt, bytecodeHash)
  }

  /** Build LZ Prover init code and predict Tron CREATE2 address */
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

  /** Call Create2Factory_Tron.deploy() and parse the Deployed event */
  private async deployViaFactory(
    initCode: string,
    salt: string,
  ): Promise<string> {
    // TronWeb v5+ uses ethers.js AbiCoder internally — values must be
    // 0x-prefixed hex strings. Salts are keccak256 outputs so already valid.
    const initCodeHex = initCode.startsWith('0x') ? initCode : '0x' + initCode

    const result =
      await this.tronWeb.transactionBuilder.triggerSmartContract(
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
      throw new Error(`Factory deploy failed: ${JSON.stringify(broadcast)}`)
    }
    console.log(`  txId: ${broadcast.txid}`)

    for (let i = 0; i < 30; i++) {
      await sleep(2000)
      const info: any = await this.tronWeb.trx.getTransactionInfo(
        broadcast.txid,
      )
      if (info?.id) {
        const logs: any[] = info.log || []
        for (const log of logs) {
          // topics[0] == Deployed event signature (no 0x prefix in Tron receipts)
          if (log.topics?.[0] === DEPLOYED_TOPIC.slice(2)) {
            // topics[1] is the indexed address, left-padded to 32 bytes
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

  /**
   * Deploy Portal on Tron directly (not via CREATE2 factory).
   * TVM does not support nested CREATE inside CREATE2, so Portal must be
   * deployed with a standard createSmartContract call.
   * Returns 0x-prefixed hex20 address.
   */
  async deployPortal(
    _portalSalt: string,
    existingPortal?: string,
  ): Promise<string> {
    if (existingPortal) {
      const hex20 = tronAddrToHex20(this.tronWeb, existingPortal)
      console.log(
        `  Using existing Tron Portal: ${existingPortal} (hex20: ${hex20})`,
      )
      return hex20
    }

    const { abi, bytecode } = loadArtifact('Portal')
    const bytecodeHex = bytecode.startsWith('0x') ? bytecode.slice(2) : bytecode

    console.log('  Deploying directly via createSmartContract...')
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
      throw new Error(`Portal broadcast failed: ${JSON.stringify(broadcast)}`)
    }

    console.log(`  txId: ${broadcast.txid}`)

    // Wait for confirmation and extract contract address
    for (let i = 0; i < 20; i++) {
      await sleep(3000)
      const info: any = await this.tronWeb.trx.getTransactionInfo(broadcast.txid)
      if (info?.id) {
        if (info.receipt?.result !== 'SUCCESS') {
          throw new Error(`Portal deployment failed: ${JSON.stringify(info)}`)
        }
        const addrHex41: string = info.contract_address
        const hex20 = '0x' + addrHex41.slice(2)
        console.log(`  Deployed at (hex20): ${hex20}`)
        return hex20
      }
    }
    throw new Error('Portal deployment timed out')
  }

  /** Deploy LZ Prover on Tron and return 0x-prefixed hex20 address */
  async deployLZProver(
    lzSalt: string,
    endpointHex20: string,
    delegateHex20: string,
    portalHex20: string,
    crossVmProvers: string[],
    predictedAddr20: string,
  ): Promise<string> {
    console.log(`  Predicted address: ${predictedAddr20}`)

    // Check if already deployed
    const base58 = this.tronWeb.address.fromHex('41' + predictedAddr20.slice(2)) as string
    const existing = await this.tronWeb.trx.getContract(base58).catch(() => null)
    if (existing?.contract_address) {
      console.log(`  Already deployed at: ${predictedAddr20}`)
      return predictedAddr20
    }

    const { initCode } = this.computeLZProver(
      lzSalt,
      endpointHex20,
      delegateHex20,
      portalHex20,
      crossVmProvers,
    )
    const actual20 = await this.deployViaFactory(initCode, lzSalt)

    if (actual20.toLowerCase() !== predictedAddr20.toLowerCase()) {
      throw new Error(
        `Tron LZProver address mismatch! Expected: ${predictedAddr20}, Got: ${actual20}`,
      )
    }
    return actual20
  }
}

// ─── DeployOrchestrator ───────────────────────────────────────────────────────

class DeployOrchestrator {
  private baseDeployer: BaseDeployer
  private tronDeployer: TronDeployer
  private isDryRun: boolean
  private isTestnet: boolean
  private abiCoder: ethers.AbiCoder

  private baseLZEndpoint: string
  private baseDelegate: string
  private tronLZEndpointHex20: string
  private tronDelegateHex20: string
  private existingBasePortal?: string
  private existingTronPortal?: string

  private portalSalt: string
  private lzSalt: string

  constructor() {
    this.isDryRun = process.argv.includes('--dry-run')
    this.isTestnet = process.argv.includes('--testnet')
    this.abiCoder = ethers.AbiCoder.defaultAbiCoder()

    // Private key (works for both Base secp256k1 and Tron)
    let privateKey = process.env.PRIVATE_KEY || ''
    if (privateKey.startsWith('0x')) privateKey = privateKey.slice(2)
    if (!privateKey && !this.isDryRun) {
      throw new Error('PRIVATE_KEY env var required')
    }
    if (!privateKey) privateKey = '0'.repeat(64) // dummy for dry-run offline predictions

    // RPC URLs
    const baseRpcUrl =
      process.env.BASE_RPC_URL ||
      (this.isTestnet ? 'https://sepolia.base.org' : '')
    if (!baseRpcUrl) throw new Error('BASE_RPC_URL required (or use --testnet)')

    const tronRpcUrl =
      process.env.TRON_RPC_URL ||
      (this.isTestnet ? 'https://api.shasta.trongrid.io' : '')
    if (!tronRpcUrl) throw new Error('TRON_RPC_URL required (or use --testnet)')

    const tronFactory =
      process.env.TRON_CREATE2_FACTORY ||
      (this.isTestnet ? TRON_SHASTA_CREATE2_FACTORY : '')
    if (!tronFactory) throw new Error('TRON_CREATE2_FACTORY required')

    // Salt computation — matches Deploy.s.sol getContractSalt() pattern
    const rootSalt = ethers.id(process.env.SALT || 'eco-routes-v1')
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

    // Initialize deployers
    this.baseDeployer = new BaseDeployer(baseRpcUrl, '0x' + privateKey)
    this.tronDeployer = new TronDeployer(tronRpcUrl, privateKey, tronFactory)

    // Base config
    this.baseLZEndpoint = process.env.BASE_LZ_ENDPOINT || ''
    this.baseDelegate =
      process.env.BASE_LZ_DELEGATE || this.baseDeployer.address

    // Tron config — normalize addresses to hex20 for ABI encoding
    const tronEndpointRaw = process.env.TRON_LZ_ENDPOINT || ''
    const tronDelegateRaw =
      process.env.TRON_LZ_DELEGATE || this.tronDeployer.address

    this.tronLZEndpointHex20 = tronEndpointRaw
      ? tronAddrToHex20(this.tronDeployer.tronWeb, tronEndpointRaw)
      : ''
    this.tronDelegateHex20 = tronDelegateRaw
      ? tronAddrToHex20(this.tronDeployer.tronWeb, tronDelegateRaw)
      : ''

    this.existingBasePortal = process.env.BASE_PORTAL_CONTRACT
    this.existingTronPortal = process.env.TRON_PORTAL_CONTRACT
  }

  async run(): Promise<void> {
    console.log('=== Base + Tron Deployment Orchestrator ===')
    console.log(`Mode:      ${this.isDryRun ? 'DRY RUN (no transactions)' : 'LIVE'}`)
    console.log(`Network:   ${this.isTestnet ? 'testnet' : 'mainnet'}`)
    console.log(`Portal salt:    ${this.portalSalt}`)
    console.log(`LZ Prover salt: ${this.lzSalt}`)
    console.log()

    // ── Step 1: Deploy Portal on Base (CREATE3) ───────────────────────────────
    console.log('=== Step 1: Portal on Base ===')
    let basePortal: string
    if (this.isDryRun) {
      basePortal = await this.baseDeployer.predictPortalAddress(this.portalSalt)
      console.log(`  [DRY RUN] Would deploy at: ${basePortal}`)
    } else {
      basePortal = await this.baseDeployer.deployPortal(
        this.portalSalt,
        this.existingBasePortal,
      )
    }

    // ── Step 2: Deploy Portal on Tron (direct, no CREATE2 — TVM limitation) ──
    console.log('\n=== Step 2: Portal on Tron ===')
    let tronPortalHex20: string
    if (this.isDryRun) {
      console.log(`  [DRY RUN] Address only known after deployment (direct deploy, not CREATE2)`)
      tronPortalHex20 = '0x0000000000000000000000000000000000000000'
    } else {
      tronPortalHex20 = await this.tronDeployer.deployPortal(
        this.portalSalt,
        this.existingTronPortal,
      )
    }

    // ── Step 3: Predict Base LayerZeroProver address (CREATE3, read-only) ────
    console.log('\n=== Step 3: Predict Base LayerZeroProver address ===')
    const baseLZProverAddr =
      await this.baseDeployer.predictLZProverAddress(this.lzSalt)
    console.log(`  Base LayerZeroProver (CREATE3): ${baseLZProverAddr}`)

    // ── Step 4: Construct Tron LZ Prover init code + predict address ──────────
    console.log('\n=== Step 4: Construct Tron LayerZeroProver ===')
    if (!this.tronLZEndpointHex20) {
      throw new Error('TRON_LZ_ENDPOINT required')
    }

    // Tron LayerZeroProver whitelist entry for the Base LZ Prover — RIGHT-aligned bytes32.
    // baseLZProverAddr is a 0x-prefixed hex20 EVM address.
    // When the Base LZ endpoint sends a packet, it sets origin.sender =
    // bytes32(uint256(uint160(addr))), i.e. right-aligned. The Tron prover's
    // allowInitializePath() calls isWhitelisted(origin.sender), so this entry must be
    // the right-aligned encoding. (Confirmed: left-aligned returns false.)
    const baseLZProverBytes32 = ethers.zeroPadValue(baseLZProverAddr, 32)
    console.log(`  Base LZ Prover (0x-hex20 → right-aligned bytes32): ${baseLZProverBytes32}`)

    const { addr20hex: tronLZProverPredicted } =
      this.tronDeployer.computeLZProver(
        this.lzSalt,
        this.tronLZEndpointHex20,
        this.tronDelegateHex20,
        tronPortalHex20,
        [baseLZProverBytes32],
      )
    console.log(`  Tron LayerZeroProver predicted: ${tronLZProverPredicted}`)

    // ── Step 5: Deploy Tron LayerZeroProver ──────────────────────────────────
    console.log('\n=== Step 5: Deploy Tron LayerZeroProver ===')
    let tronLZProverAddr: string
    if (this.isDryRun) {
      console.log(`  [DRY RUN] Would deploy at: ${tronLZProverPredicted}`)
      tronLZProverAddr = tronLZProverPredicted
    } else {
      tronLZProverAddr = await this.tronDeployer.deployLZProver(
        this.lzSalt,
        this.tronLZEndpointHex20,
        this.tronDelegateHex20,
        tronPortalHex20,
        [baseLZProverBytes32],
        tronLZProverPredicted,
      )
    }

    // ── Step 6: Deploy Base LayerZeroProver via CREATE3 ───────────────────────
    console.log('\n=== Step 6: Deploy Base LayerZeroProver ===')
    if (!this.baseLZEndpoint) {
      throw new Error('BASE_LZ_ENDPOINT required')
    }

    // Base LayerZeroProver whitelist entry for the Tron LZ Prover — LEFT-aligned bytes32.
    // tronLZProverAddr is a 0x-prefixed hex20 address (strip of the hex41 0x41 prefix).
    // When the Tron LZ endpoint sends a packet, origin.sender encodes the Tron contract
    // address as bytes32(bytes20(addr)) — left-aligned (address occupies the high 20 bytes).
    // The Base prover's allowInitializePath() calls isWhitelisted(origin.sender), so this
    // entry must be the left-aligned encoding. (Confirmed: right-aligned returns false.)
    // Equivalent Solidity: bytes32(bytes20(tronLZProverAddr))
    const tronLZProverBytes32 = addressToBytes32Left(tronLZProverAddr)
    console.log(`  Tron LZ Prover (0x-hex20 → left-aligned bytes32): ${tronLZProverBytes32}`)

    let baseLZProverFinal: string
    if (this.isDryRun) {
      console.log(`  [DRY RUN] Would deploy at: ${baseLZProverAddr}`)
      baseLZProverFinal = baseLZProverAddr
    } else {
      baseLZProverFinal = await this.baseDeployer.deployLZProver(
        this.lzSalt,
        this.baseLZEndpoint,
        this.baseDelegate,
        basePortal,
        [tronLZProverBytes32],
        baseLZProverAddr,
      )
    }

    // Confirm Base LZ Prover address matches prediction
    if (
      baseLZProverFinal.toLowerCase() !== baseLZProverAddr.toLowerCase()
    ) {
      throw new Error(
        `Base LZProver address mismatch! Expected: ${baseLZProverAddr}, Got: ${baseLZProverFinal}`,
      )
    }

    // ── Step 7: Summary ───────────────────────────────────────────────────────
    const toTronBase58 = (hex20: string) =>
      this.tronDeployer.tronWeb.address.fromHex('41' + hex20.slice(2)) as string

    const tronPortalBase58 = toTronBase58(tronPortalHex20)
    const tronLZProverBase58 = toTronBase58(tronLZProverAddr)

    console.log('\n=== Deployment Summary ===')
    console.log(`  Base Portal:            ${basePortal}`)
    console.log(`  Base LayerZeroProver:   ${baseLZProverFinal}`)
    console.log(`  Tron Portal (b58):      ${tronPortalBase58}`)
    console.log(`  Tron Portal (0x-hex20): ${tronPortalHex20}`)
    console.log(`  Tron LZ Prover (b58):   ${tronLZProverBase58}`)
    console.log(`  Tron LZ Prover (0x-hex20): ${tronLZProverAddr}`)

    console.log('\n=== Post-Deployment LZ Configuration Notes ===')
    console.log('  Whitelist encodings (immutable — fixed at deploy time):')
    console.log(`    Tron prover whitelist (receives from Base):`)
    console.log(`      Base LZ Prover (0x-hex20) → right-aligned bytes32: ${baseLZProverBytes32}`)
    console.log(`    Base prover whitelist (receives from Tron):`)
    console.log(`      Tron LZ Prover (0x-hex20) → left-aligned bytes32:  ${tronLZProverBytes32}`)
    console.log()
    console.log('  LZ send/receive library configs:')
    console.log('    Both chains use default configs set by LZ Labs — no setConfig() call needed.')
    console.log('    Default DVN: LZ Labs DVN (confirmed via docs/lzDeployments.json).')
    console.log('    To override (custom DVN or executor), call IMessageLibManager.setConfig()')
    console.log('    on the LZ endpoint using the delegate address set at deploy time.')
    console.log()
    console.log('  DVN testnet caveat:')
    console.log('    On Tron Shasta, the LZ Labs DVN off-chain worker may not actively process')
    console.log('    Tron→EVM routes. On-chain DVNFeePaid event fires and fees are paid, but')
    console.log('    proof delivery to Base may not occur. Contact LZ Labs to confirm support.')
    console.log()
    console.log('  No setPeer() needed: LayerZeroProver uses Whitelist.sol (set above) instead.')
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
    process.exit(1)
  })
}

export default DeployOrchestrator
