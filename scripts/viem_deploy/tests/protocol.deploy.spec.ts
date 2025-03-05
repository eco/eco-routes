const mockOnIdle = jest.fn()
const mockAdd = jest.fn()
const mockGetJsonFromFile = jest.fn()
const mockMergeAddresses = jest.fn()
const mockSaveDeploySalts = jest.fn()
const mockEmpty = jest.fn()
const mockGitRandomSalt = jest.fn()
const mockCreateFile = jest.fn()
const mockStorageProverSupported = jest.fn()
const mockSimulateContract = jest.fn()
const mockWriteContract = jest.fn()
const mockWaitForTransactionReceipt = jest.fn()
const mockWaitForNonceUpdate = jest.fn()
const mockGetDeployChainConfig = jest.fn()
const mockAddJsonAddress = jest.fn()
const mockEncodeDeployData = jest.fn()
const mockVerifyContract = jest.fn()
const mockWaitMs = jest.fn()
const mockGetClient = jest.fn()

import { optimismSepolia } from 'viem/chains'
import { SaltsType } from '../../deploy/addresses'
import { DeployChains } from '../chains'
//mock before ProtocolDeploy import to prevent jest import issues
jest.mock('p-queue', () => {
  return class {
    queue = [] as any
    onIdle = mockOnIdle
    add = mockAdd
    constructor() {}
  }
})
import { DeployOpts, ProtocolDeploy } from '../ProtocolDeploy'
import { zeroAddress } from 'viem'

jest.mock('lodash', () => {
  return {
    isEmpty: mockEmpty,
  }
})

jest.mock('../../utils', () => {
  return {
    ...jest.requireActual('../../utils'),
    storageProverSupported: mockStorageProverSupported,
    waitForNonceUpdate: mockWaitForNonceUpdate,
    getDeployChainConfig: mockGetDeployChainConfig,
    waitMs: mockWaitMs,
  }
})

jest.mock('../../deploy/addresses', () => {
  return {
    ...jest.requireActual('../../deploy/addresses'),
    getJsonFromFile: mockGetJsonFromFile,
    mergeAddresses: mockMergeAddresses,
    createFile: mockCreateFile,
    saveDeploySalts: mockSaveDeploySalts,
    addJsonAddress: mockAddJsonAddress,
  }
})

jest.mock('../utils', () => {
  return {
    ...jest.requireActual('../utils'),
    getGitRandomSalt: mockGitRandomSalt,
    getClient: mockGetClient,
  }
})

jest.mock('../verify', () => {
  return {
    ...jest.requireActual('../verify'),
    verifyContract: mockVerifyContract,
  }
})

jest.mock('viem', () => {
  return {
    ...jest.requireActual('viem'),
    encodeDeployData: mockEncodeDeployData,
  }
})

describe('ProtocolDeployment Tests', () => {
  const salts: SaltsType = { salt: '0x1234', saltPre: '0x9876' }
  let pd: ProtocolDeploy
  const mockDeploy = jest.fn()

  beforeEach(() => {
    jest.resetAllMocks()
    process.env.DEPLOYER_PRIVATE_KEY =
      '0x1110002221bf287c8f88282152916470378ead952851e97f681cf48121a2f4aa'
  })

  beforeAll(() => {
    console.log = jest.fn()
    console.debug = jest.fn()
    console.error = jest.fn()
  })

  describe('on constructor', () => {
    it('should initialize with default values', async () => {
      const pd = new ProtocolDeploy()
      expect(pd['deployChains']).toEqual(DeployChains)
      expect(Object.keys(pd['clients']).length).toEqual(DeployChains.length)
      expect(pd['salts']).toBeUndefined()
      expect(mockCreateFile).toHaveBeenCalledTimes(1)
    })
  })

  describe('on deployFullNetwork', () => {
    it('should set the salts from the constructor if they are defined', async () => {
      pd = new ProtocolDeploy([], salts)
      pd.deployAndVerifyContract = mockDeploy
      mockEmpty.mockReturnValue(false)
      await pd.deployFullNetwork()
      expect(mockEmpty).toHaveBeenCalledTimes(1)
      expect(mockEmpty).toHaveBeenCalledWith(salts)
      expect(mockGitRandomSalt).not.toHaveBeenCalled()
    })

    it('should generate salts if not defined as constructor input', async () => {
      pd = new ProtocolDeploy([])
      pd.deployAndVerifyContract = mockDeploy
      mockEmpty.mockReturnValue(true)
      await pd.deployFullNetwork()
      expect(mockEmpty).toHaveBeenCalledTimes(1)
      expect(mockEmpty).toHaveBeenCalledWith(undefined)
      expect(mockGitRandomSalt).toHaveBeenCalledTimes(2)
    })

    it('should save salts to file', async () => {
      pd = new ProtocolDeploy([], salts)
      pd.deployAndVerifyContract = mockDeploy
      mockEmpty.mockReturnValue(false)
      await pd.deployFullNetwork()
      expect(mockSaveDeploySalts).toHaveBeenCalledTimes(1)
      expect(mockSaveDeploySalts).toHaveBeenCalledWith(salts)
    })

    it('should await verification queue', async () => {
      pd = new ProtocolDeploy([], salts)
      pd.deployAndVerifyContract = mockDeploy
      mockEmpty.mockReturnValue(false)
      await pd.deployFullNetwork()
      expect(mockOnIdle).toHaveBeenCalledTimes(1)
    })

    describe('on deploy loop', () => {
      const ds = [optimismSepolia].flat()
      beforeEach(() => {
        pd = new ProtocolDeploy(ds, salts)
        pd.deployViemContracts = mockDeploy
        mockEmpty.mockReturnValue(false)
      })
      describe('on concurrent', () => {
        it('should should add chains to deploy queue', async () => {
          mockAdd.mockImplementation(async (fn) => {
            await fn()
          })
          await pd.deployFullNetwork(true)
          expect(mockAdd).toHaveBeenCalledTimes(ds.length)
          expect(mockDeploy).toHaveBeenCalledTimes(ds.length * 2)
        })

        it('should await idle', async () => {
          await pd.deployFullNetwork(true)
          expect(mockOnIdle).toHaveBeenCalledTimes(2)
        })
      })

      describe('on non-concurrent', () => {
        it('should should deploy contracts if not concurrent', async () => {
          await pd.deployFullNetwork(false)
          expect(mockDeploy).toHaveBeenCalledTimes(ds.length * 2)
        })
      })
    })
  })

  describe('on deploy and verify', () => {
    const ds = [optimismSepolia].flat()
    // const mockProver = jest.fn()
    const mockIntentSource = jest.fn()
    const mockInbox = jest.fn()
    const c = ds[0]
    const s = salts['salt']
    const opts: DeployOpts = { deployType: 'create3', retry: true }

    beforeEach(() => {
      mockGetClient.mockReturnValue({
        simulateContract: mockSimulateContract,
        writeContract: mockWriteContract,
        waitForTransactionReceipt: mockWaitForTransactionReceipt,
      })
      pd = new ProtocolDeploy(ds, salts)
      // pd.deployProver = mockProver
      pd.deployIntentSource = mockIntentSource
      pd.deployInbox = mockInbox
      mockEmpty.mockReturnValue(false)
    })

    describe('on deployViemContracts', () => {
      beforeEach(() => {
        pd.deployViemContracts(c, s, opts)
      })

      // it('should deploy the prover', async () => {
      //   expect(mockProver).toHaveBeenCalledTimes(1)
      //   expect(mockProver).toHaveBeenCalledWith(c, s, opts)
      // })

      it('should deploy the intent source', async () => {
        expect(mockIntentSource).toHaveBeenCalledTimes(1)
        expect(mockIntentSource).toHaveBeenCalledWith(c, s, opts)
      })

      it('should deploy the inbox and hyperlane prover', async () => {
        expect(mockInbox).toHaveBeenCalledTimes(1)
        expect(mockInbox).toHaveBeenCalledWith(c, s, true, opts)
      })
    })

    describe('on deployAndVerifyContract', () => {
      let params = { name: 'IntentSource', abi: 'abi' } as any
      const deployerContract = { address: '0x999', abi: 'abi' }
      const encoded = '0x1234abdcd'
      const salts = 'salts'
      let mockSalt: any
      let mockDep: any
      let request = { dploy: 'stuff' }
      let result = '0x1234'
      const mockDepAddress = '0x1abc34'
      const networkConfig = { pre: false, chainId: 11155420 }

      const mockGetDeployedAddress = jest.fn().mockReturnValue(null)
      beforeEach(() => {
        mockGetDeployChainConfig.mockReturnValue(networkConfig)
        mockWaitForNonceUpdate.mockImplementation(
          async (client, address, pollInterval, txCall) => {
            await txCall()
          },
        )
        mockSalt = jest.spyOn(ProtocolDeploy.prototype, 'transformSalt')

        mockSalt.mockReturnValue(salts)
        mockDep = jest.spyOn(ProtocolDeploy.prototype, 'getDepoyerContract')
        mockDep.mockReturnValue(deployerContract)
        mockSimulateContract.mockResolvedValue({ request, result })
        mockStorageProverSupported.mockReturnValue(true)
        mockEncodeDeployData.mockReturnValue(encoded)

        pd.getDeployedAddress = mockGetDeployedAddress
      })

      afterEach(() => {
        jest.resetAllMocks()
      })

      describe('on throw', () => {
        it('should throw if retry is false', async () => {
          mockSimulateContract.mockRejectedValueOnce(new Error('throw'))
          await expect(
            async () =>
              await pd.deployAndVerifyContract(c, s, params, { retry: false }),
          ).rejects.toThrow('Contract address is null, might not have deployed')
        })

        it('should retry on throw if retry is true, and throw if retry fails', async () => {
          mockSimulateContract.mockRejectedValue(new Error('throw'))
          const depSpy = jest.spyOn(
            ProtocolDeploy.prototype,
            'deployAndVerifyContract',
          )

          await expect(
            async () =>
              await pd.deployAndVerifyContract(c, s, params, { retry: true }),
          ).rejects.toThrow('Contract address is null, might not have deployed')
          expect(mockWaitMs).toHaveBeenCalledTimes(1)
          expect(depSpy).toHaveBeenCalledTimes(2)
          expect(depSpy).toHaveBeenLastCalledWith(c, s, params, {
            retry: false,
          })
          //important to restore
          depSpy.mockRestore()
        })
      })

      it('should not deploy prover to an unsupported network', async () => {
        mockStorageProverSupported.mockReturnValue(false)
        expect(await pd.deployAndVerifyContract(c, s, params)).toEqual(
          zeroAddress,
        )
        expect(mockStorageProverSupported).toHaveBeenCalledTimes(1)
      })

      it('should default to create3 deployment', async () => {
        //should call transformSalt
        await pd.deployAndVerifyContract(c, s, params)
        expect(mockSalt).toHaveBeenCalledTimes(1)
        expect(mockSalt).toHaveBeenCalledWith(s, params.name)
      })

      it('should simulate and deploy', async () => {
        await pd.deployAndVerifyContract(c, s, params)
        expect(mockSimulateContract).toHaveBeenCalledTimes(1)
        expect(mockWriteContract).toHaveBeenCalledTimes(1)
        expect(mockWaitForTransactionReceipt).toHaveBeenCalledTimes(1)

        expect(mockSimulateContract).toHaveBeenCalledWith({
          address: deployerContract.address,
          abi: deployerContract.abi,
          functionName: 'deploy',
          args: [encoded, salts],
        })
      })

      it('should not deploy if contract is already deployed', async () => {
        mockGetDeployedAddress.mockReturnValue(mockDepAddress)
        await pd.deployAndVerifyContract(c, s, params)
        expect(mockSimulateContract).toHaveBeenCalledTimes(0)
        expect(mockWriteContract).toHaveBeenCalledTimes(0)
        expect(mockWaitForTransactionReceipt).toHaveBeenCalledTimes(0)
        expect(mockAddJsonAddress).toHaveBeenCalledWith(
          networkConfig,
          params.name,
          mockDepAddress,
        )
      })

      it('should not verify if contract is already deployed', async () => {
        mockGetDeployedAddress.mockReturnValue(mockDepAddress)
        await pd.deployAndVerifyContract(c, s, params)
        expect(mockVerifyContract).toHaveBeenCalledTimes(0)
        expect(mockAdd).toHaveBeenCalledTimes(0)
      })

      it('should save json deploy address to file', async () => {
        await pd.deployAndVerifyContract(c, s, params)
        expect(mockAddJsonAddress).toHaveBeenCalledTimes(1)
        expect(mockAddJsonAddress).toHaveBeenCalledWith(
          networkConfig,
          params.name,
          result,
        )
      })

      it('should add to verify queue the deployed contract', async () => {
        mockAdd.mockImplementation(async (fn) => {
          await fn()
        })
        mockGetDeployedAddress.mockReturnValue(null)
        await pd.deployAndVerifyContract(c, s, params)
        expect(mockAdd).toHaveBeenCalledTimes(1)
        expect(mockVerifyContract).toHaveBeenCalledTimes(1)
      })

      it('should return the deployed address', async () => {
        expect(await pd.deployAndVerifyContract(c, s, params)).toEqual(result)
      })
    })
  })
})
