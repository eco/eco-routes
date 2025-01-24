const mockExtract = jest.fn()
const mockGetJsonFromFile = jest.fn()
const mockMergeAddresses = jest.fn()
const mockRim = jest.fn()
const MockDeployChains = [{ id: 1 }, { id: 2 }, { id: 3 }]

import { ProtocolVersion } from '../ProtocolVersion'
import { DeployChains } from '../chains'

jest.mock('rimraf', () => {
  return {
    rimrafSync: mockRim,
  }
})
jest.mock('pacote', () => {
  return {
    extract: mockExtract,
  }
})
jest.mock('../chains', () => {
  return {
    DeployChains: MockDeployChains,
  }
})

jest.mock('../../deploy/addresses', () => {
  return {
    ...jest.requireActual('../../deploy/addresses'),
    getJsonFromFile: mockGetJsonFromFile,
    mergeAddresses: mockMergeAddresses,
  }
})

describe('ProtocolVersion Tests', () => {
  beforeEach(() => {
    jest.resetAllMocks()
  })

  beforeAll(() => {
    console.log = jest.fn()
    console.debug = jest.fn()
    console.error = jest.fn()
  })
  describe('on constructor', () => {
    it('should set the version to that given arg', () => {
      let pv = new ProtocolVersion('1.0.0')
      expect(pv.getVersion()).toEqual('1.0.0')
      expect(pv.getReleaseTag()).toEqual('latest')

      pv = new ProtocolVersion('1.0.0-latest')
      expect(pv.getVersion()).toEqual('1.0.0')
      expect(pv.getReleaseTag()).toEqual('latest')

      pv = new ProtocolVersion('1.0.0-latest')
      expect(pv.getVersion()).toEqual('1.0.0')
      expect(pv.getReleaseTag()).toEqual('latest')

      pv = new ProtocolVersion('1.0.0-beta')
      expect(pv.getVersion()).toEqual('1.0.0')
      expect(pv.getReleaseTag()).toEqual('beta')

      pv = new ProtocolVersion('v1.0.0-beta')
      expect(pv.getVersion()).toEqual('1.0.0')
      expect(pv.getReleaseTag()).toEqual('beta')

      pv = new ProtocolVersion('1.0.0-rc')
      expect(pv.getVersion()).toEqual('1.0.0')
      expect(pv.getReleaseTag()).toEqual('rc')

      pv = new ProtocolVersion('v1.0.0-rc')
      expect(pv.getVersion()).toEqual('1.0.0')
      expect(pv.getReleaseTag()).toEqual('rc')
    })

    it('should throw if given version arg that is invalid', () => {
      expect(() => new ProtocolVersion('invalid')).toThrow(
        'Invalid version: invalid',
      )
      expect(() => new ProtocolVersion('version1.2')).toThrow(
        'Invalid version: version1.2',
      )
    })

    it('should set the version to the tag to env if not given', () => {
      process.env.GITHUB_REF = 'refs/tags/v1.0.0'
      let pv = new ProtocolVersion()
      expect(pv.getVersion()).toEqual('1.0.0')
      expect(pv.getReleaseTag()).toEqual('latest')
      process.env.GITHUB_REF = 'refs/tags/v1.0.0-beta'
      pv = new ProtocolVersion()
      expect(pv.getVersion()).toEqual('1.0.0')
      expect(pv.getReleaseTag()).toEqual('beta')
    })

    it('should throw if version tag from env is invalid', () => {
      process.env.GITHUB_REF = 'v1.0.0'
      expect(() => new ProtocolVersion()).toThrow('GITHUB_REF is not a tag')
    })
  })

  describe('on updateProtocolVersion', () => {
    it('should call the package and .sol file updates', () => {
      const spy = jest.spyOn(ProtocolVersion.prototype, 'updateProjectVersion')
      const mockVersionSol = jest.fn()
      const mockUpdatePackage = jest.fn()
      jest
        .spyOn(ProtocolVersion.prototype, 'updateVersionInSolidityFiles')
        .mockImplementation(mockVersionSol)
      jest
        .spyOn(ProtocolVersion.prototype, 'updatePackageJsonVersion')
        .mockImplementation(mockUpdatePackage)

      const pv = new ProtocolVersion('1.0.0')
      pv.updateProjectVersion()
      expect(spy).toHaveBeenCalledTimes(1)
      expect(mockVersionSol).toHaveBeenCalled() //recursive call so we dont know how many times
      expect(mockUpdatePackage).toHaveBeenCalledTimes(1)
    })
  })

  describe('on isPatchUpdate', () => {
    let pv: ProtocolVersion
    const versionString = '0.0.2-beta'
    beforeEach(() => {
      pv = new ProtocolVersion(versionString)
    })
    it('should return false if no published version for tag exists', async () => {
      jest
        .spyOn(ProtocolVersion.prototype, 'getPublishedVersion')
        .mockResolvedValue('')
      expect(await pv.isPatchUpdate()).toBe(false)
    })

    it('should throw is the release version is the same as this', async () => {
      jest
        .spyOn(ProtocolVersion.prototype, 'getPublishedVersion')
        .mockResolvedValue(versionString)
      await expect(async () => await pv.isPatchUpdate()).rejects.toThrow(
        `Version of git tag ${versionString} is the same as the current published version: ${versionString}`,
      )
    })

    it('should return false if this version is lower patch than the published one', async () => {
      jest
        .spyOn(ProtocolVersion.prototype, 'getPublishedVersion')
        .mockResolvedValue('0.0.21-beta')
      expect(await pv.isPatchUpdate()).toBe(false)
    })

    it('should return true if this version is a patch higher than the published one', async () => {
      jest
        .spyOn(ProtocolVersion.prototype, 'getPublishedVersion')
        .mockResolvedValue('0.0.19-beta')
      expect(await pv.isPatchUpdate()).toBe(true)
    })
  })

  describe('on getNewChains', () => {
    let pv: ProtocolVersion
    const versionString = '0.0.2-beta'
    beforeEach(() => {
      jest.resetAllMocks()
      pv = new ProtocolVersion(versionString)
      mockExtract.mockResolvedValue({})

      mockGetJsonFromFile.mockReturnValue({
        '1': {},
        '2': {},
        '3-pre': {},
      })
    })

    it("should return all chains if it can't extract the package", async () => {
      mockExtract.mockRejectedValue(new Error('error'))
      expect(await pv.getNewChains()).toEqual(DeployChains)
    })

    it('should return all the chains not inlcuded in the package', async () => {
      const cs = await pv.getNewChains()
      // expect(mockRim).toHaveBeenCalledTimes(1)
      expect(cs.length).toEqual(1)
      expect(cs[0].id).toEqual(3)
    })
  })

  describe('on getDeployChains', () => {
    let pv: ProtocolVersion
    const versionString = '0.0.2-beta'
    beforeEach(() => {
      jest.restoreAllMocks()
      pv = new ProtocolVersion(versionString)
      mockExtract.mockResolvedValue({})

      mockGetJsonFromFile.mockReturnValue({
        '1': {},
        '2': {},
        '3-pre': {},
      })
    })

    it('should throw if a patch update has no new chains', async () => {
      jest
        .spyOn(ProtocolVersion.prototype, 'isPatchUpdate')
        .mockResolvedValue(true)
      jest
        .spyOn(ProtocolVersion.prototype, 'getNewChains')
        .mockResolvedValue([])
      await expect(async () => await pv.getDeployChains()).rejects.toThrow(
        'No new chains to deploy for a patch update',
      )
    })

    it('should call getNewChains if its a patch update', async () => {
      jest
        .spyOn(ProtocolVersion.prototype, 'isPatchUpdate')
        .mockResolvedValue(true)
      const spy = jest.spyOn(ProtocolVersion.prototype, 'getNewChains')
      await pv.getDeployChains()
      expect(spy).toHaveBeenCalledTimes(1)
    })

    it('should return the salts if its a patch update', async () => {
      jest
        .spyOn(ProtocolVersion.prototype, 'isPatchUpdate')
        .mockResolvedValue(true)
      const spy = jest.spyOn(ProtocolVersion.prototype, 'getNewChains')
      const salts = { salt: '0x1', saltPre: '0x2' }
      mockGetJsonFromFile.mockReturnValue(salts)
      expect(await pv.getDeployChains()).toEqual({
        chains: MockDeployChains,
        salts,
      })
      expect(spy).toHaveBeenCalledTimes(1)
    })

    it('should return all the deploy chains if its not a patch', async () => {
      jest
        .spyOn(ProtocolVersion.prototype, 'isPatchUpdate')
        .mockResolvedValue(false)
      const spy = jest.spyOn(ProtocolVersion.prototype, 'getNewChains')
      expect(await pv.getDeployChains()).toEqual({ chains: MockDeployChains })
      expect(spy).toHaveBeenCalledTimes(0)
    })
  })
})
