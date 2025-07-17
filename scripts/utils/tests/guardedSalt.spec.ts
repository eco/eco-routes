import {
  describe,
  it,
  expect,
  beforeAll,
  beforeEach,
  afterEach,
} from '@jest/globals'
import {
  keccak256,
  encodePacked,
  getAddress,
  toHex,
  hexToBytes,
  bytesToHex,
  createPublicClient,
  http,
  parseAbi,
  Hex,
} from 'viem'
import { mainnet } from 'viem/chains'
import {
  createGuardedSalt,
  createGuardedSaltForDeployer,
  parseSalt,
  validateGuardedSalt,
  SenderBytes,
  RedeployProtectionFlag,
  DEPLOYER_ADDRESS,
  DEFAULT_DEPLOYER_ADDRESS,
} from '../guardedSalt'
import { computeCreate3AddressCreateX } from '../addressUtils'

describe('GuardedSalt', () => {
  const testDeployer = '0xB963326B9969f841361E6B6605d7304f40f6b414'
  const testSalt =
    '0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
  const testChainId = 1
  const createxAddress = '0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed'

  let publicClient: ReturnType<typeof createPublicClient>

  // Mock console.log to suppress logs during tests
  beforeEach(() => {
    jest.spyOn(console, 'log').mockImplementation(() => {})
  })

  afterEach(() => {
    jest.restoreAllMocks()
  })

  beforeAll(() => {
    // Create a public client for mainnet to verify against CreateX
    publicClient = createPublicClient({
      chain: mainnet,
      transport: http(),
    })
  })

  describe('createGuardedSalt', () => {
    it('should create a guarded salt without cross-chain protection', () => {
      const guardedSalt = createGuardedSalt({
        deployer: testDeployer,
        salt: testSalt,
        crossChainProtection: false,
      })

      expect(guardedSalt).toMatch(/^0x[a-fA-F0-9]{64}$/)
      expect(guardedSalt).not.toBe(testSalt)
    })

    it('should create a guarded salt with cross-chain protection', () => {
      const guardedSalt = createGuardedSalt({
        deployer: testDeployer,
        salt: testSalt,
        crossChainProtection: true,
        chainId: testChainId,
      })

      expect(guardedSalt).toMatch(/^0x[a-fA-F0-9]{64}$/)
      expect(guardedSalt).not.toBe(testSalt)
    })

    it('should create different guarded salts for different deployers', () => {
      const deployer1 = '0xB963326B9969f841361E6B6605d7304f40f6b414'
      const deployer2 = '0x1234567890123456789012345678901234567890'

      const guardedSalt1 = createGuardedSalt({
        deployer: deployer1,
        salt: testSalt,
        crossChainProtection: false,
      })

      const guardedSalt2 = createGuardedSalt({
        deployer: deployer2,
        salt: testSalt,
        crossChainProtection: false,
      })

      expect(guardedSalt1).not.toBe(guardedSalt2)
    })

    it('should create different guarded salts for different salts', () => {
      const salt1 =
        '0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
      const salt2 =
        '0xfedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210'

      const guardedSalt1 = createGuardedSalt({
        deployer: testDeployer,
        salt: salt1,
        crossChainProtection: false,
      })

      const guardedSalt2 = createGuardedSalt({
        deployer: testDeployer,
        salt: salt2,
        crossChainProtection: false,
      })

      expect(guardedSalt1).not.toBe(guardedSalt2)
    })

    it('should create different guarded salts with and without cross-chain protection', () => {
      const guardedSalt1 = createGuardedSalt({
        deployer: testDeployer,
        salt: testSalt,
        crossChainProtection: false,
      })

      const guardedSalt2 = createGuardedSalt({
        deployer: testDeployer,
        salt: testSalt,
        crossChainProtection: true,
        chainId: testChainId,
      })

      expect(guardedSalt1).not.toBe(guardedSalt2)
    })

    it('should create different guarded salts for different chain IDs', () => {
      const guardedSalt1 = createGuardedSalt({
        deployer: testDeployer,
        salt: testSalt,
        crossChainProtection: true,
        chainId: 1,
      })

      const guardedSalt2 = createGuardedSalt({
        deployer: testDeployer,
        salt: testSalt,
        crossChainProtection: true,
        chainId: 137,
      })

      expect(guardedSalt1).not.toBe(guardedSalt2)
    })
  })

  describe('createGuardedSaltForDeployer', () => {
    it('should create a guarded salt for the specific deployer', () => {
      const guardedSalt = createGuardedSaltForDeployer(testSalt, false)

      expect(guardedSalt).toMatch(/^0x[a-fA-F0-9]{64}$/)
      expect(guardedSalt).not.toBe(testSalt)
    })

    it('should create a guarded salt with cross-chain protection', () => {
      const guardedSalt = createGuardedSaltForDeployer(
        testSalt,
        true,
        testChainId,
      )

      expect(guardedSalt).toMatch(/^0x[a-fA-F0-9]{64}$/)
      expect(guardedSalt).not.toBe(testSalt)
    })

    it('should be equivalent to createGuardedSalt with the specific deployer', () => {
      const guardedSalt1 = createGuardedSaltForDeployer(testSalt, false)
      const guardedSalt2 = createGuardedSalt({
        deployer: testDeployer,
        salt: testSalt,
        crossChainProtection: false,
      })

      expect(guardedSalt1).toBe(guardedSalt2)
    })
  })

  describe('parseSalt', () => {
    it('should parse a salt with msg.sender and true protection flag', () => {
      // Create a salt with deployer address + 0x01 + random bytes
      const saltBytes = new Uint8Array(32)
      saltBytes.set(hexToBytes(testDeployer), 0)
      saltBytes.set([0x01], 20)
      saltBytes.set(hexToBytes(testSalt).slice(-11), 21)
      const salt = bytesToHex(saltBytes) as `0x${string}`

      const result = parseSalt(salt, testDeployer)
      expect(result.senderBytes).toBe(SenderBytes.MsgSender)
      expect(result.redeployProtectionFlag).toBe(RedeployProtectionFlag.True)
    })

    it('should parse a salt with msg.sender and false protection flag', () => {
      // Create a salt with deployer address + 0x00 + random bytes
      const saltBytes = new Uint8Array(32)
      saltBytes.set(hexToBytes(testDeployer), 0)
      saltBytes.set([0x00], 20)
      saltBytes.set(hexToBytes(testSalt).slice(-11), 21)
      const salt = bytesToHex(saltBytes) as `0x${string}`

      const result = parseSalt(salt, testDeployer)
      expect(result.senderBytes).toBe(SenderBytes.MsgSender)
      expect(result.redeployProtectionFlag).toBe(RedeployProtectionFlag.False)
    })

    it('should parse a salt with zero address and true protection flag', () => {
      // Create a salt with zero address + 0x01 + random bytes
      const saltBytes = new Uint8Array(32)
      saltBytes.set(new Uint8Array(20), 0) // Zero address
      saltBytes.set([0x01], 20)
      saltBytes.set(hexToBytes(testSalt).slice(-11), 21)
      const salt = bytesToHex(saltBytes) as `0x${string}`

      const result = parseSalt(salt, testDeployer)
      expect(result.senderBytes).toBe(SenderBytes.ZeroAddress)
      expect(result.redeployProtectionFlag).toBe(RedeployProtectionFlag.True)
    })

    it('should parse a random salt', () => {
      const result = parseSalt(testSalt, testDeployer)
      expect(result.senderBytes).toBe(SenderBytes.Random)
      expect(result.redeployProtectionFlag).toBe(RedeployProtectionFlag.False)
    })
  })

  describe('validateGuardedSalt', () => {
    it('should validate a correctly generated guarded salt', () => {
      const guardedSalt = createGuardedSalt({
        deployer: testDeployer,
        salt: testSalt,
        crossChainProtection: false,
      })

      const isValid = validateGuardedSalt(guardedSalt, testSalt, testDeployer)
      expect(isValid).toBe(true)
    })

    it('should validate a correctly generated guarded salt with cross-chain protection', () => {
      const guardedSalt = createGuardedSalt({
        deployer: testDeployer,
        salt: testSalt,
        crossChainProtection: true,
        chainId: testChainId,
      })

      const isValid = validateGuardedSalt(
        guardedSalt,
        testSalt,
        testDeployer,
        testChainId,
      )
      expect(isValid).toBe(true)
    })

    it('should reject an invalid guarded salt', () => {
      const guardedSalt = createGuardedSalt({
        deployer: testDeployer,
        salt: testSalt,
        crossChainProtection: false,
      })

      const wrongDeployer = '0x1234567890123456789012345678901234567890'
      const isValid = validateGuardedSalt(guardedSalt, testSalt, wrongDeployer)
      expect(isValid).toBe(false)
    })

    it('should reject a guarded salt with wrong chain ID', () => {
      const guardedSalt = createGuardedSalt({
        deployer: testDeployer,
        salt: testSalt,
        crossChainProtection: true,
        chainId: 1,
      })

      const isValid = validateGuardedSalt(
        guardedSalt,
        testSalt,
        testDeployer,
        137,
      )
      expect(isValid).toBe(false)
    })
  })

  describe('constants and validation', () => {
    it('should have correct DEFAULT_DEPLOYER_ADDRESS', () => {
      expect(DEFAULT_DEPLOYER_ADDRESS).toBe(
        '0xB963326B9969f841361E6B6605d7304f40f6b414',
      )
    })

    it('should have valid DEPLOYER_ADDRESS', () => {
      expect(DEPLOYER_ADDRESS).toMatch(/^0x[a-fA-F0-9]{40}$/)
      expect(DEPLOYER_ADDRESS).toBe(DEFAULT_DEPLOYER_ADDRESS) // Should be default in test env
    })

    it('should throw error when deployer is not provided', () => {
      expect(() => {
        createGuardedSalt({
          deployer: '' as `0x${string}`,
          salt: testSalt,
          crossChainProtection: false,
        })
      }).toThrow('Deployer address is required for guarded salt generation')
    })

    it('should throw error when deployer is invalid', () => {
      expect(() => {
        createGuardedSalt({
          deployer: 'invalid_address' as `0x${string}`,
          salt: testSalt,
          crossChainProtection: false,
        })
      }).toThrow()
    })
  })

  describe('integration tests', () => {
    it('should work with real world scenario', () => {
      const deployer = '0xB963326B9969f841361E6B6605d7304f40f6b414'
      const baseSalt = keccak256(
        encodePacked(['string'], ['HYPER_PROVER_SALT']),
      )
      const chainId = 1

      // Create guarded salt for mainnet deployment
      const guardedSalt = createGuardedSalt({
        deployer,
        salt: baseSalt,
        crossChainProtection: true,
        chainId,
      })

      // Validate it
      const isValid = validateGuardedSalt(
        guardedSalt,
        baseSalt,
        deployer,
        chainId,
      )
      expect(isValid).toBe(true)

      // Should be different for different chain
      const guardedSaltPolygon = createGuardedSalt({
        deployer,
        salt: baseSalt,
        crossChainProtection: true,
        chainId: 137,
      })

      expect(guardedSalt).not.toBe(guardedSaltPolygon)
    })

    it('should be deterministic', () => {
      const guardedSalt1 = createGuardedSaltForDeployer(testSalt, false)
      const guardedSalt2 = createGuardedSaltForDeployer(testSalt, false)

      expect(guardedSalt1).toBe(guardedSalt2)
    })

    it('should work with different salt lengths', () => {
      const shortSalt =
        '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef'
      const longSalt =
        '0xfedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321'

      const guardedSalt1 = createGuardedSaltForDeployer(shortSalt, false)
      const guardedSalt2 = createGuardedSaltForDeployer(longSalt, false)

      expect(guardedSalt1).not.toBe(guardedSalt2)
      expect(guardedSalt1).toMatch(/^0x[a-fA-F0-9]{64}$/)
      expect(guardedSalt2).toMatch(/^0x[a-fA-F0-9]{64}$/)
    })
  })

  describe('CreateX Contract Verification', () => {
    const createXAbi = parseAbi([
      'function computeCreate3Address(bytes32 salt, address deployer) external pure returns (address)',
      'function computeCreate3Address(bytes32 salt) external view returns (address)',
    ])

    it('should verify CreateX contract exists on mainnet', async () => {
      const code = await publicClient.getCode({ address: createxAddress })
      expect(code).toBeDefined()
      expect(code).not.toBe('0x')
    })

    it('should verify guarded salt addresses against CreateX contract', async () => {
      const originalSalt = keccak256(
        encodePacked(['string'], ['CREATE_X_VERIFICATION']),
      )

      // Create guarded salt without cross-chain protection
      const guardedSalt = createGuardedSalt({
        deployer: testDeployer,
        salt: originalSalt,
        crossChainProtection: false,
      })

      // Compute address using our implementation
      const ourAddress = computeCreate3AddressCreateX(guardedSalt, testDeployer)

      // Get address from CreateX contract
      const contractAddress = await publicClient.readContract({
        address: createxAddress,
        abi: createXAbi,
        functionName: 'computeCreate3Address',
        args: [guardedSalt, testDeployer],
      })

      expect(ourAddress).toBe(contractAddress)
    })

    it('should verify guarded salt addresses with cross-chain protection', async () => {
      const originalSalt = keccak256(
        encodePacked(['string'], ['CROSS_CHAIN_VERIFICATION']),
      )

      // Create guarded salt with cross-chain protection
      const guardedSalt = createGuardedSalt({
        deployer: testDeployer,
        salt: originalSalt,
        crossChainProtection: true,
        chainId: 1,
      })

      // Compute address using our implementation
      const ourAddress = computeCreate3AddressCreateX(guardedSalt, testDeployer)

      // Get address from CreateX contract
      const contractAddress = await publicClient.readContract({
        address: createxAddress,
        abi: createXAbi,
        functionName: 'computeCreate3Address',
        args: [guardedSalt, testDeployer],
      })

      expect(ourAddress).toBe(contractAddress)
    })

    it('should verify multiple guarded salts against CreateX contract', async () => {
      const testCases = [
        { name: 'HYPER_PROVER', crossChain: false },
        { name: 'INBOX', crossChain: false },
        { name: 'META_PROVER', crossChain: true, chainId: 1 },
        { name: 'OUTBOX', crossChain: true, chainId: 137 },
      ]

      for (const testCase of testCases) {
        const originalSalt = keccak256(
          encodePacked(['string'], [testCase.name]),
        )

        // Create guarded salt
        const guardedSalt = createGuardedSalt({
          deployer: testDeployer,
          salt: originalSalt,
          crossChainProtection: testCase.crossChain,
          chainId: testCase.chainId,
        })

        // Compute address using our implementation
        const ourAddress = computeCreate3AddressCreateX(
          guardedSalt,
          testDeployer,
        )

        // Get address from CreateX contract
        const contractAddress = await publicClient.readContract({
          address: createxAddress,
          abi: createXAbi,
          functionName: 'computeCreate3Address',
          args: [guardedSalt, testDeployer],
        })

        expect(ourAddress).toBe(contractAddress)
      }
    })

    it('should verify HyperProver deployment scenario against CreateX', async () => {
      const rootSalt = keccak256(
        encodePacked(['string'], ['ECO_ROUTES_DEPLOYMENT']),
      )
      const hyperProverSalt = keccak256(
        encodePacked(
          ['bytes32', 'bytes32'],
          [rootSalt, keccak256(encodePacked(['string'], ['HYPER_PROVER']))],
        ),
      )

      // Create guarded salt for mainnet deployment
      const guardedSalt = createGuardedSalt({
        deployer: testDeployer,
        salt: hyperProverSalt,
        crossChainProtection: true,
        chainId: 1,
      })

      // Compute address using our implementation
      const ourAddress = computeCreate3AddressCreateX(guardedSalt, testDeployer)

      // Get address from CreateX contract
      const contractAddress = await publicClient.readContract({
        address: createxAddress,
        abi: createXAbi,
        functionName: 'computeCreate3Address',
        args: [guardedSalt, testDeployer],
      })

      expect(ourAddress).toBe(contractAddress)
      expect(ourAddress).toMatch(/^0x[a-fA-F0-9]{40}$/)
      expect(ourAddress).not.toBe('0x0000000000000000000000000000000000000000')
    })

    it('should verify different deployers produce different addresses', async () => {
      const originalSalt = keccak256(
        encodePacked(['string'], ['DEPLOYER_VERIFICATION']),
      )
      const deployers = [
        '0xB963326B9969f841361E6B6605d7304f40f6b414',
        '0x1234567890123456789012345678901234567890',
        '0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD',
      ]

      const addresses = []

      for (const deployer of deployers as Hex[]) {
        const guardedSalt = createGuardedSalt({
          deployer,
          salt: originalSalt,
          crossChainProtection: false,
        })

        // Compute address using our implementation
        const ourAddress = computeCreate3AddressCreateX(guardedSalt, deployer)

        // Get address from CreateX contract
        const contractAddress = await publicClient.readContract({
          address: createxAddress,
          abi: createXAbi,
          functionName: 'computeCreate3Address',
          args: [guardedSalt, deployer],
        })

        expect(ourAddress).toBe(contractAddress)
        addresses.push(ourAddress)
      }

      // All addresses should be different
      for (let i = 0; i < addresses.length; i++) {
        for (let j = i + 1; j < addresses.length; j++) {
          expect(addresses[i]).not.toBe(addresses[j])
        }
      }
    })

    it('should verify guarded salt with CreateX as deployer', async () => {
      const originalSalt = keccak256(
        encodePacked(['string'], ['CREATEX_DEPLOYER_TEST']),
      )

      // Create guarded salt using CreateX contract as deployer
      const guardedSalt = createGuardedSalt({
        deployer: createxAddress,
        salt: originalSalt,
        crossChainProtection: false,
      })

      // Compute address using our implementation
      const ourAddress = computeCreate3AddressCreateX(
        guardedSalt,
        createxAddress,
      )

      // Get address from CreateX contract using its own address as deployer
      const contractAddress = await publicClient.readContract({
        address: createxAddress,
        abi: createXAbi,
        functionName: 'computeCreate3Address',
        args: [guardedSalt, createxAddress],
      })

      expect(ourAddress).toBe(contractAddress)
    })

    it('should verify guarded salt validation against CreateX results', async () => {
      const originalSalt = keccak256(
        encodePacked(['string'], ['VALIDATION_TEST']),
      )

      // Create guarded salt
      const guardedSalt = createGuardedSalt({
        deployer: testDeployer,
        salt: originalSalt,
        crossChainProtection: false,
      })

      // Validate our guarded salt
      const isValid = validateGuardedSalt(
        guardedSalt,
        originalSalt,
        testDeployer,
      )
      expect(isValid).toBe(true)

      // Compute address using our implementation
      const ourAddress = computeCreate3AddressCreateX(guardedSalt, testDeployer)

      // Get address from CreateX contract
      const contractAddress = await publicClient.readContract({
        address: createxAddress,
        abi: createXAbi,
        functionName: 'computeCreate3Address',
        args: [guardedSalt, testDeployer],
      })

      // Should match CreateX contract
      expect(ourAddress).toBe(contractAddress)
    })

    it('should verify performance compared to CreateX contract calls', async () => {
      const originalSalt = keccak256(
        encodePacked(['string'], ['PERFORMANCE_TEST']),
      )
      const iterations = 5

      // Create guarded salt
      const guardedSalt = createGuardedSalt({
        deployer: testDeployer,
        salt: originalSalt,
        crossChainProtection: false,
      })

      // Time our implementation
      const startTimeOur = Date.now()
      let ourAddress: string
      for (let i = 0; i < iterations; i++) {
        ourAddress = computeCreate3AddressCreateX(guardedSalt, testDeployer)
      }
      const endTimeOur = Date.now()
      const durationOur = endTimeOur - startTimeOur

      // Time CreateX contract calls
      const startTimeContract = Date.now()
      let contractAddress: string
      for (let i = 0; i < iterations; i++) {
        contractAddress = await publicClient.readContract({
          address: createxAddress,
          abi: createXAbi,
          functionName: 'computeCreate3Address',
          args: [guardedSalt, testDeployer],
        })
      }
      const endTimeContract = Date.now()
      const durationContract = endTimeContract - startTimeContract

      // Results should match
      expect(ourAddress!).toBe(contractAddress!)

      // Our implementation should be faster (no network calls)
      expect(durationOur).toBeLessThan(durationContract)
    })
  })
})
