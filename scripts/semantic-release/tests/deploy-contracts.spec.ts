import { spawn } from 'child_process'
import path from 'path'
import fs from 'fs'
import { Logger } from '../../utils/extract-salt'

// Mock the imports to avoid actual implementation calls
jest.mock('child_process', () => ({
  spawn: jest.fn()
}))

jest.mock('fs', () => ({
  mkdirSync: jest.fn(),
  writeFileSync: jest.fn(),
  readFileSync: jest.fn(),
  existsSync: jest.fn(),
  unlinkSync: jest.fn()
}))

jest.mock('path', () => ({
  join: jest.fn((...args) => args.join('/'))
}))

// Mock the other module imports
jest.mock('../../utils/extract-salt', () => ({
  determineSalts: jest.fn().mockResolvedValue({
    rootSalt: '0xroot-salt-hash',
    preprodRootSalt: '0xpreprod-salt-hash'
  })
}))

jest.mock('../../deploy/addresses', () => ({
  transformAddresses: jest.fn()
}))

jest.mock('../../deploy/csv', () => ({
  addressesToCVS: jest.fn()
}))

// Import the functions to be tested
import {
  preparePlugin,
  processContractsForJson,
  deployContracts
} from '../deploy-contracts'

// Access the internal function for testing
// Since this is not exported, we need to mock it
const setupEnvAndDeploy = jest.fn().mockImplementation(() => Promise.resolve())

// Mock the module to expose our mocked setupEnvAndDeploy
jest.mock('../deploy-contracts', () => {
  // Get the actual module first
  const originalModule = jest.requireActual('../deploy-contracts')
  
  // Return modified module with our mock
  return {
    ...originalModule,
    setupEnvAndDeploy: setupEnvAndDeploy,
    parseDeploymentResults: jest.fn().mockImplementation((filePath) => {
      if (!fs.existsSync(filePath)) {
        return []
      }
      
      const fileContent = fs.readFileSync(filePath)
      return fileContent
        .split('\n')
        .map((line) => line.trim())
        .filter((line) => line.length)
        .map((line) => {
          const [chainId, address, contractPath] = line.split(',')
          if (!chainId || !address || !contractPath) {
            return null
          }
          
          const [, contractName] = contractPath.split(':')
          return {
            address,
            name: contractName,
            chainId: parseInt(chainId)
          }
        })
        .filter(Boolean)
    })
  }
}, { virtual: true })

describe('Deploy Contracts Module', () => {
  // Reset all mocks before each test
  beforeEach(() => {
    jest.clearAllMocks()
    
    // Default mock implementations
    const mockSpawnEventEmitter = {
      on: jest.fn().mockImplementation((event, callback) => {
        if (event === 'close') {
          // Simulate successful process completion
          setTimeout(() => callback(0), 10)
        }
        return mockSpawnEventEmitter
      })
    }
    
    // @ts-ignore - TypeScript doesn't know about our mocked implementation
    spawn.mockImplementation(() => mockSpawnEventEmitter)
    
    // Mock fs functions
    fs.existsSync.mockReturnValue(true)
    fs.readFileSync.mockImplementation((path) => {
      if (path.includes('package.json')) {
        return JSON.stringify({ name: '@eco-foundation/routes', version: '1.0.0' })
      }
      if (path.includes('deployment-results.txt')) {
        return '1,0xAddress1,contracts/ContractA.sol:ContractA\n10,0xAddress2,contracts/ContractB.sol:ContractB'
      }
      return ''
    })
    
    // Set required environment variables
    process.env.PRIVATE_KEY = 'test-private-key'
    process.env.CHAIN_IDS = '1,10'
  })
  
  afterEach(() => {
    delete process.env.PRIVATE_KEY
    delete process.env.CHAIN_IDS
    jest.resetAllMocks()
  })

  describe('preparePlugin', () => {
    it('should skip deployment if no release is detected', async () => {
      const logger = { log: jest.fn(), error: jest.fn(), warn: jest.fn() }
      const context = { logger, cwd: '/test' }
      
      await preparePlugin({}, context)
      
      expect(logger.log).toHaveBeenCalledWith('No release detected, skipping contract deployment')
      expect(setupEnvAndDeploy).not.toHaveBeenCalled()
    })
    
    it('should determine salts and deploy contracts for a valid release', async () => {
      const logger = { log: jest.fn(), error: jest.fn(), warn: jest.fn() }
      const nextRelease = { version: '1.2.3', gitTag: 'v1.2.3', notes: 'Test release' }
      const context = { nextRelease, logger, cwd: '/test' }
      
      await preparePlugin({}, context)
      
      expect(logger.log).toHaveBeenCalledWith('Preparing to deploy contracts for version 1.2.3')
      expect(setupEnvAndDeploy).toHaveBeenCalledWith(
        [
          { salt: '0xroot-salt-hash', environment: 'production' },
          { salt: '0xpreprod-salt-hash', environment: 'preprod' }
        ],
        logger,
        '/test'
      )
      expect(logger.log).toHaveBeenCalledWith('✅ Contract deployment completed successfully')
    })
    
    it('should handle errors during deployment', async () => {
      const logger = { log: jest.fn(), error: jest.fn(), warn: jest.fn() }
      const nextRelease = { version: '1.2.3', gitTag: 'v1.2.3', notes: 'Test release' }
      const context = { nextRelease, logger, cwd: '/test' }
      
      // Setup mock to throw an error
      setupEnvAndDeploy.mockRejectedValueOnce(new Error('Test error'))
      
      await expect(preparePlugin({}, context)).rejects.toThrow('Test error')
      
      expect(logger.error).toHaveBeenCalledWith('❌ Contract deployment failed')
      expect(logger.error).toHaveBeenCalledWith('Test error')
    })
  })

  describe('deployContracts', () => {
    it('should reject if deployment script is not found', async () => {
      const logger = { log: jest.fn(), error: jest.fn(), warn: jest.fn() }
      
      // Mock fs.existsSync to return false for the script path
      fs.existsSync.mockImplementation((path) => {
        if (path.includes('MultiDeploy.sh')) return false
        return true
      })
      
      await expect(deployContracts('0xsalt', logger, '/test'))
        .rejects.toThrow('Deployment script not found at /test/scripts/MultiDeploy.sh')
    })
    
    it('should spawn the deployment process with correct environment variables', async () => {
      const logger = { log: jest.fn(), error: jest.fn(), warn: jest.fn() }
      
      await deployContracts('0xsalt', logger, '/test')
      
      expect(spawn).toHaveBeenCalledWith(
        '/test/scripts/MultiDeploy.sh',
        [],
        {
          env: expect.objectContaining({
            SALT: '0xsalt',
            OUTPUT_DIR: '/test/out'
          }),
          stdio: 'inherit',
          shell: true,
          cwd: '/test'
        }
      )
    })
    
    it('should return empty contracts if deployment process fails', async () => {
      const logger = { log: jest.fn(), error: jest.fn(), warn: jest.fn() }
      
      // Mock spawn to simulate a failed process
      const mockSpawnEventEmitter = {
        on: jest.fn().mockImplementation((event, callback) => {
          if (event === 'close') {
            // Simulate failed process completion
            setTimeout(() => callback(1), 10)
          }
          return mockSpawnEventEmitter
        })
      }
      
      // @ts-ignore - TypeScript doesn't know about our mocked implementation
      spawn.mockImplementation(() => mockSpawnEventEmitter)
      
      const result = await deployContracts('0xsalt', logger, '/test')
      
      expect(result).toEqual({
        contracts: [],
        success: false
      })
    })
    
    it('should handle missing results file', async () => {
      const logger = { log: jest.fn(), error: jest.fn(), warn: jest.fn() }
      
      // Mock spawn to simulate a successful process
      const mockSpawnEventEmitter = {
        on: jest.fn().mockImplementation((event, callback) => {
          if (event === 'close') {
            // Simulate successful process completion
            setTimeout(() => callback(0), 10)
          }
          return mockSpawnEventEmitter
        })
      }
      
      // @ts-ignore - TypeScript doesn't know about our mocked implementation
      spawn.mockImplementation(() => mockSpawnEventEmitter)
      
      // Mock fs.existsSync to return false for the results file
      fs.existsSync.mockImplementation((path) => {
        if (path.includes('deployment-results.txt')) return false
        return true
      })
      
      const result = await deployContracts('0xsalt', logger, '/test')
      
      expect(logger.error).toHaveBeenCalledWith('Deployment results file not found at /test/out/deployment-results.txt')
      expect(result).toEqual({
        contracts: [],
        success: false
      })
    })
  })

  describe('processContractsForJson', () => {
    it('should group contracts by chain ID and environment', () => {
      const contracts = [
        { address: '0x123', name: 'ContractA', chainId: 1, environment: 'production' },
        { address: '0x456', name: 'ContractB', chainId: 1, environment: 'production' },
        { address: '0x789', name: 'ContractA', chainId: 1, environment: 'preprod' },
        { address: '0xabc', name: 'ContractB', chainId: 10, environment: 'production' }
      ]
      
      const result = processContractsForJson(contracts)
      
      expect(result).toEqual({
        '1': {
          'ContractA': '0x123',
          'ContractB': '0x456'
        },
        '1-pre': {
          'ContractA': '0x789'
        },
        '10': {
          'ContractB': '0xabc'
        }
      })
    })
    
    it('should handle empty contracts array', () => {
      const result = processContractsForJson([])
      
      expect(result).toEqual({})
    })
    
    it('should handle contracts without environment', () => {
      const contracts = [
        { address: '0x123', name: 'ContractA', chainId: 1 },
        { address: '0x456', name: 'ContractB', chainId: 10 }
      ]
      
      const result = processContractsForJson(contracts)
      
      expect(result).toEqual({
        '1': {
          'ContractA': '0x123'
        },
        '10': {
          'ContractB': '0x456'
        }
      })
    })
  })
})