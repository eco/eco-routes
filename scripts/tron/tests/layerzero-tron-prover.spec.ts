import { ethers } from 'ethers'
import * as fs from 'fs'
import * as path from 'path'
import {
  buildTronLayerZeroProverInitCode,
  predictTronCreate2Address,
  tronDomainConfig,
} from '../layerzero-tron-prover'

const addr = (n: number) => '0x' + n.toString(16).padStart(40, '0')
const chain = (eid: number, extra: Record<string, unknown> = {}) => ({
  name: `chain-${eid}`,
  eid,
  confirmations: 10,
  endpointV2: addr(eid * 10 + 1),
  sendUln302: addr(eid * 10 + 2),
  receiveUln302: addr(eid * 10 + 3),
  executor: addr(eid * 10 + 4),
  dvns: {
    canary: addr(eid * 10 + 5),
    lzLabs: addr(eid * 10 + 6),
    horizen: addr(eid * 10 + 7),
  },
  ...extra,
})

const POLICY = {
  policy: {
    requiredDVNs: ['canary', 'lzLabs', 'horizen'],
    maxMessageSize: 10000,
  },
  crossVmProvers: [],
  chains: {
    '8453': chain(30184),
    '1': chain(30101),
    '728126428': chain(30420, { vm: 'tron' }),
  },
}

const EVM_PROVER = '0xEc00FE5F9625328757A0648934EAbe9A5685a541'
const PORTAL = '0xbbe65c636a745ccb12fb0a8376f5ed089a86983a'
const DELEGATE = '0x6cae25455bf5fcf19ce737ad50ee3bc481fcddd4'
const BYTECODE = '0x6080604052'

const CTOR = [
  'address',
  'address',
  'address',
  'bytes32[]',
  'uint256',
  'tuple(uint64 domain, uint64 chainId)[]',
]

describe('tronDomainConfig', () => {
  it('maps every EVM chain of the policy eid -> chainId, ordered by chain id, never Tron', () => {
    expect(tronDomainConfig(POLICY)).toEqual([
      { domain: 30101n, chainId: 1n },
      { domain: 30184n, chainId: 8453n },
    ])
  })

  it('refuses a policy without a Tron chain', () => {
    const { ['728126428']: _tron, ...evmOnly } = POLICY.chains
    expect(() => tronDomainConfig({ ...POLICY, chains: evmOnly })).toThrow(
      /Tron/,
    )
  })
})

describe('buildTronLayerZeroProverInitCode', () => {
  const build = () =>
    buildTronLayerZeroProverInitCode(BYTECODE, POLICY, {
      evmProver: EVM_PROVER,
      portal: PORTAL,
      delegate: DELEGATE,
    })

  it('appends the six v2.12 constructor args: endpoint, delegate, portal, [evm prover], 200k, domains', () => {
    const { initCode } = build()
    expect(initCode.startsWith(BYTECODE)).toBe(true)
    const [endpoint, delegate, portal, provers, minGas, domains] =
      ethers.AbiCoder.defaultAbiCoder().decode(
        CTOR,
        '0x' + initCode.slice(BYTECODE.length),
      )
    expect(endpoint.toLowerCase()).toBe(POLICY.chains['728126428'].endpointV2)
    expect(delegate.toLowerCase()).toBe(DELEGATE)
    expect(portal.toLowerCase()).toBe(PORTAL)
    expect(provers).toEqual([ethers.zeroPadValue(EVM_PROVER.toLowerCase(), 32)])
    expect(minGas).toBe(200000n)
    expect(
      domains.map((d: { domain: bigint; chainId: bigint }) => [
        d.domain,
        d.chainId,
      ]),
    ).toEqual([
      [30101n, 1n],
      [30184n, 8453n],
    ])
  })

  it("matches the compiled LayerZeroProver's own constructor encoding", () => {
    const artifact = path.join(
      __dirname,
      '../../../out/LayerZeroProver.sol/LayerZeroProver.json',
    )
    if (!fs.existsSync(artifact)) return // needs `forge build`
    const { abi } = JSON.parse(fs.readFileSync(artifact, 'utf8'))
    const { initCode } = build()
    const expected = new ethers.Interface(abi).encodeDeploy([
      POLICY.chains['728126428'].endpointV2,
      DELEGATE,
      PORTAL,
      [ethers.zeroPadValue(EVM_PROVER.toLowerCase(), 32)],
      200000n,
      [
        { domain: 30101n, chainId: 1n },
        { domain: 30184n, chainId: 8453n },
      ],
    ])
    expect('0x' + initCode.slice(BYTECODE.length)).toBe(expected)
  })

  it.each(['evmProver', 'portal', 'delegate'])(
    'refuses a zero or malformed %s',
    (field) => {
      const args = {
        evmProver: EVM_PROVER,
        portal: PORTAL,
        delegate: DELEGATE,
        [field]: addr(0),
      }
      expect(() =>
        buildTronLayerZeroProverInitCode(BYTECODE, POLICY, args),
      ).toThrow(field)
      const bad = {
        evmProver: EVM_PROVER,
        portal: PORTAL,
        delegate: DELEGATE,
        [field]: '0x12',
      }
      expect(() =>
        buildTronLayerZeroProverInitCode(BYTECODE, POLICY, bad),
      ).toThrow(field)
    },
  )
})

describe('predictTronCreate2Address', () => {
  it("uses Tron's 0x41 CREATE2 prefix", () => {
    const factory = addr(0xfac)
    const salt = ethers.zeroPadValue('0x01', 32)
    const hash = ethers.keccak256(BYTECODE)
    const expected =
      '0x' +
      ethers.keccak256(ethers.concat(['0x41', factory, salt, hash])).slice(-40)
    expect(predictTronCreate2Address(factory, salt, BYTECODE)).toBe(expected)
  })
})
