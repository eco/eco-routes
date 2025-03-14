const mockGetJsonFromFile = jest.fn()
const mockMergeAddresses = jest.fn()

import { ProtocolVersion } from '../ProtocolVersion'

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
})
