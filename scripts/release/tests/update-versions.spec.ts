import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'
import {
  updateSolidityVersions,
  updatePackageJsonVersion,
} from '../update-versions'

const VERSIONED_CONTRACT = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

abstract contract Semver {
    /**
     * @notice Returns the semantic version of the contract
     */
    function version() external pure returns (string memory) {
        return "2.6";
    }
}
`

const UNVERSIONED_CONTRACT = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract Plain {
    function foo() external pure returns (uint256) {
        return 1;
    }
}
`

describe('update-versions', () => {
  let rootDir: string

  beforeEach(() => {
    rootDir = fs.mkdtempSync(path.join(os.tmpdir(), 'update-versions-'))
    fs.mkdirSync(path.join(rootDir, 'contracts', 'libs'), { recursive: true })
    fs.writeFileSync(
      path.join(rootDir, 'contracts', 'libs', 'Semver.sol'),
      VERSIONED_CONTRACT,
    )
    fs.writeFileSync(
      path.join(rootDir, 'contracts', 'Plain.sol'),
      UNVERSIONED_CONTRACT,
    )
    fs.writeFileSync(
      path.join(rootDir, 'package.json'),
      JSON.stringify({ name: 'x', version: '0.0.0' }, null, 2) + '\n',
    )
  })

  afterEach(() => {
    fs.rmSync(rootDir, { recursive: true, force: true })
  })

  it('rewrites version() with the full x.y.z string, recursively', () => {
    const updated = updateSolidityVersions(rootDir, '3.2.7')

    expect(updated).toHaveLength(1)
    const content = fs.readFileSync(
      path.join(rootDir, 'contracts', 'libs', 'Semver.sol'),
      'utf8',
    )
    expect(content).toContain('return "3.2.7";')
    expect(content).not.toContain('return "2.6";')
  })

  it('produces compilable-shaped output (single well-formed function)', () => {
    updateSolidityVersions(rootDir, '3.2.7')
    const content = fs.readFileSync(
      path.join(rootDir, 'contracts', 'libs', 'Semver.sol'),
      'utf8',
    )
    expect(content).toContain(
      'function version() external pure returns (string memory) { return "3.2.7"; }',
    )
  })

  it('leaves files without a version() function untouched', () => {
    updateSolidityVersions(rootDir, '3.2.7')
    const content = fs.readFileSync(
      path.join(rootDir, 'contracts', 'Plain.sol'),
      'utf8',
    )
    expect(content).toBe(UNVERSIONED_CONTRACT)
  })

  it('is idempotent (second run reports zero updates)', () => {
    updateSolidityVersions(rootDir, '3.2.7')
    const second = updateSolidityVersions(rootDir, '3.2.7')
    expect(second).toHaveLength(0)
  })

  it('bumps an already-rewritten single-line version() to a new version', () => {
    updateSolidityVersions(rootDir, '3.2.7')
    const bumped = updateSolidityVersions(rootDir, '3.2.8')

    expect(bumped).toHaveLength(1)
    const content = fs.readFileSync(
      path.join(rootDir, 'contracts', 'libs', 'Semver.sol'),
      'utf8',
    )
    expect(content).toContain(
      'function version() external pure returns (string memory) { return "3.2.8"; }',
    )
    expect(content).not.toContain('3.2.7')
  })

  it('returns an empty list when nothing matches the rewrite pattern', () => {
    fs.rmSync(path.join(rootDir, 'contracts', 'libs', 'Semver.sol'))
    const updated = updateSolidityVersions(rootDir, '3.2.7')
    expect(updated).toHaveLength(0)
  })

  it('updates package.json version without touching other fields', () => {
    updatePackageJsonVersion(rootDir, '3.2.7')
    const pkg = JSON.parse(
      fs.readFileSync(path.join(rootDir, 'package.json'), 'utf8'),
    )
    expect(pkg).toEqual({ name: 'x', version: '3.2.7' })
  })
})
