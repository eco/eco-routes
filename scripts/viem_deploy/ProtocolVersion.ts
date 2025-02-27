import * as fs from 'fs'
import * as path from 'path'
import semver from 'semver-utils'
import PackageJson from '../../package.json'
import { getGithubTagRef, getPublishedPackages } from './git.utils'
import { compareSemverIntegerStrings } from './utils'
import { getGitHashShort } from '../publish/gitUtils'

// Directory containing Solidity contract files
const contractsDir = path.join(__dirname, '../../contracts')

// Regular expression to verify that a string is a valid SemVer
// default regex from https://semver.org/#is-there-a-suggested-regular-expression-regex-to-check-a-semver-string  with an optional leading v
const SEMVER_REGEX =
  /^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$/

// The tags that can be used to publish the package
export type PublishTag = 'beta' | 'latest' | 'rc'

/**
 * Given a version number MAJOR.MINOR.PATCH, increment the:
 *
 * 1. MAJOR version when you make incompatible API changes
 * 2. MINOR version when you add functionality in a backward compatible manner
 * 3. PATCH version when you make backward compatible bug fixes. This inlcudes
 * partial releases where we add chain support with no new features
 *
 * Additional labels for pre-release and build metadata are available as extensions to the MAJOR.MINOR.PATCH format.
 */
export class ProtocolVersion {
  // The version of the protocol
  version: semver.SemVer
  packageName: string = PackageJson.name

  constructor(version?: string) {
    this.version = semver.parse(this.verifySemver(version || getGithubTagRef()))
    this.version.release = this.version.release || 'latest'
  }

  /**
   * Verify that the version is a valid SemVer
   */
  verifySemver(version: string): string {
    if (!SEMVER_REGEX.test(version)) {
      console.error(`Invalid version: ${version}`)
      throw new Error(`Invalid version: ${version}`)
    }
    if (version.startsWith('v')) {
      version = version.substring(1)
    }
    return version
  }

  // Returns the version of the protocol
  getVersion(): string {
    return this.version.version || semver.stringify(this.version)
  }

  /**
   * Updates the version of the project in the solidity files and the package.json file
   */
  updateProjectVersion() {
    this.updateVersionInSolidityFiles()
    this.updatePackageJsonVersion()
  }

  /**
   * This function updates all the .sol files in the given directory to return a version string with the given version.
   * Its assumed that the files already have the function signature `function version() external pure returns (string memory)`
   *
   * @param dir the directory to update the version in the solidity files, default is the contracts directory
   * @param version the version to update the solidity files to, default is the current version
   */
  updateVersionInSolidityFiles(
    dir: string = contractsDir,
    version: string = this.getVersion(),
  ) {
    const files = fs.readdirSync(dir)
    const gitHash = getGitHashShort()
    files.forEach((file) => {
      const filePath = path.join(dir, file)
      const stat = fs.statSync(filePath)

      if (stat.isDirectory()) {
        this.updateVersionInSolidityFiles(filePath, version)
      } else if (filePath.endsWith('.sol')) {
        let content = fs.readFileSync(filePath, 'utf8')
        const versionRegex =
          /function version\(\) external pure returns \(string memory\) \{[^}]*\}/
        const newVersionFunction = `function version() external pure returns (string memory) { return "${version}-${gitHash}"; }`
        content = content.replace(versionRegex, newVersionFunction)
        fs.writeFileSync(filePath, content, 'utf8')
        console.log(`Updated Version in ${filePath}`)
      }
    })
  }

  /**
   * Updates the package json version to the given version
   *
   */
  updatePackageJsonVersion() {
    const version = this.getVersion()
    // Update the version in package.json
    const packageJsonPath = path.join(__dirname, '../../package.json')
    const packageJson = fs.readFileSync(packageJsonPath, 'utf8')
    const packageJsonObj = JSON.parse(packageJson)
    packageJsonObj.version = version
    fs.writeFileSync(
      packageJsonPath,
      JSON.stringify(packageJsonObj, null, 2),
      'utf8',
    )
  }

  /**
   * Checks the current published version of this package on npm and returns true if the current version is a patch update from the published version.
   * Patch update would be the third number in the semver string 0.0.x.
   * If no published version is found for the npm build tag, it returns false.
   *
   * @returns true if the current version is a patch update from the published version
   */
  async isPatchUpdate(): Promise<boolean> {
    const publishedVersion = await this.getPublishedVersion(
      this.getReleaseTag(),
    )
    if (!publishedVersion) return false
    const pub = semver.parse(publishedVersion)
    // in case the wrong string was published under another tag, ie 1.0.0-beta was published under latest
    pub.release = this.getReleaseTag()
    if (
      pub.major === this.version.major &&
      pub.minor === this.version.minor &&
      pub.patch === this.version.patch
    ) {
      throw new Error(
        `Version of git tag ${semver.stringify(this.version)} is the same as the current published version: ${publishedVersion}`,
      )
    }

    return (
      pub.major === this.version.major &&
      pub.minor === this.version.minor &&
      compareSemverIntegerStrings(this.version.patch || '0', pub.patch || '0') >
        0
    )
  }

  /**
   * Parses the version tag to release for the tag type
   * @returns 'beta' | 'rc' | 'latest', throws otherwise
   */
  getReleaseTag(): PublishTag {
    const releaseTag = this.version.release
    switch (releaseTag) {
      case 'beta':
        return 'beta'
      case 'rc':
        return 'rc'
      case 'latest':
        return 'latest'
      default:
        throw new Error(`Invalid release tag: ${releaseTag}`)
    }
  }

  /**
   * Gets the published dist-tag for the package on npm. If the tag is left
   * empty, it defaults to the release tag of the @link{this.version.release}
   * @param tag the npm build tag
   * @returns
   */
  async getPublishedVersion(tag: PublishTag): Promise<string | undefined> {
    const showPkg = JSON.parse(await getPublishedPackages(this.packageName))
    return showPkg['dist-tags'][tag]
  }
}
