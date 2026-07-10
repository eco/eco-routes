/**
 * semantic-release prepare hook (called via @semantic-release/exec):
 * writes the released version into every ISemver `version()` function under
 * contracts/ and into package.json.
 *
 * Usage: npx tsx scripts/release/update-versions.ts <x.y.z>
 *
 * The version string is compiled into bytecode; changing it changes CREATE2
 * deployment addresses. Full major.minor.patch is intentional (see
 * CLAUDE/specs/2026-07-08-semver-release-design.md).
 */
import { execFileSync } from 'child_process'
import * as fs from 'fs'
import * as path from 'path'

const VERSION_FUNCTION_REGEX =
  /function version\(\) external pure returns \(string memory\) \{[^}]*\}/

const SEMVER_REGEX = /^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/

export function updateSolidityVersions(
  rootDir: string,
  version: string,
): string[] {
  const updated: string[] = []

  function walk(dir: string): void {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const fullPath = path.join(dir, entry.name)
      if (entry.isDirectory()) {
        walk(fullPath)
      } else if (entry.name.endsWith('.sol')) {
        const content = fs.readFileSync(fullPath, 'utf8')
        if (!VERSION_FUNCTION_REGEX.test(content)) {
          continue
        }
        const next = content.replace(
          VERSION_FUNCTION_REGEX,
          `function version() external pure returns (string memory) { return "${version}"; }`,
        )
        if (next !== content) {
          fs.writeFileSync(fullPath, next, 'utf8')
          updated.push(fullPath)
        }
      }
    }
  }

  walk(path.join(rootDir, 'contracts'))
  return updated
}

export function updatePackageJsonVersion(
  rootDir: string,
  version: string,
): void {
  const pkgPath = path.join(rootDir, 'package.json')
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'))
  const next = { ...pkg, version }
  fs.writeFileSync(pkgPath, JSON.stringify(next, null, 2) + '\n', 'utf8')
}

export function main(argv: string[]): void {
  const version = argv[2]
  if (!version || !SEMVER_REGEX.test(version)) {
    throw new Error(
      `Usage: npx tsx scripts/release/update-versions.ts <x.y.z> (got: ${version ?? 'nothing'})`,
    )
  }
  const rootDir = process.cwd()
  const updated = updateSolidityVersions(rootDir, version)
  if (updated.length === 0) {
    throw new Error(
      `No version() function was rewritten under contracts/ — the source no longer matches the rewrite pattern. Aborting so the release fails loudly instead of tagging an unchanged version.`,
    )
  }
  // Format only the rewritten files so release commits stay version-only and
  // never sweep unrelated format drift into deployed-source history
  execFileSync('npx', ['prettier', '--write', ...updated], {
    cwd: rootDir,
    stdio: 'inherit',
  })
  updatePackageJsonVersion(rootDir, version)
  console.log(
    `Updated ${updated.length} Solidity file(s) and package.json to ${version}`,
  )
  for (const file of updated) {
    console.log(`  - ${path.relative(rootDir, file)}`)
  }
}

if (require.main === module) {
  main(process.argv)
}
