/**
 * Rebuilds @eco-foundation/routes-ts from an already published version, replacing every
 * contract ABI and bytecode it ships with this checkout's Hardhat artifacts.
 *
 * The package's addresses (deployAddresses.csv and dist/index) and its export set are kept
 * exactly as published; only the files under dist/abi are regenerated, in the same format
 * the removed semantic-release builder wrote (XAbi, XAbiType, XBytecode, XDeployedBytecode).
 * Use it when a published version carries new addresses but ABIs from an older checkout.
 *
 * Usage (from the release commit, after `yarn build`):
 *   npx tsx scripts/routes-ts/rebuild-package.ts --base 3.2.23 --version 3.2.24
 *
 * Writes build/routes-ts-<version>/eco-foundation-routes-ts-<version>.tgz and prints its
 * sha256. Publish with `npm publish <tgz>`.
 */
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

const PACKAGE = '@eco-foundation/routes-ts'
const ABI_DIRS = ['contracts', 'interfaces'] as const

function arg(name: string): string {
  const index = process.argv.indexOf(`--${name}`)
  const value = index === -1 ? undefined : process.argv[index + 1]
  if (!value) throw new Error(`missing --${name}`)
  return value
}

function findArtifact(artifactsDir: string, name: string): string {
  const matches: string[] = []
  const walk = (dir: string) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name)
      if (entry.isDirectory()) walk(full)
      else if (entry.name === `${name}.json`) matches.push(full)
    }
  }
  walk(artifactsDir)
  if (matches.length !== 1) {
    throw new Error(
      `expected one artifact for ${name}, found ${matches.length}: ${matches.join(', ')}`,
    )
  }
  return matches[0]
}

// Same output as the builder removed in #410 (sr-build-package.ts generateAbiTypeScriptFiles).
function abiSource(artifactPath: string): string {
  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'))
  const name: string = artifact.contractName
  return (
    `/**\n * ABI for the ${name} contract\n */\n` +
    `export const ${name}Abi = ${JSON.stringify(artifact.abi, null, 2)} as const\n\n` +
    `/**\n * Type-safe ABI for the ${name} contract\n */\n` +
    `export type ${name}AbiType = typeof ${name}Abi\n\n` +
    `/**\n * Bytecode for the ${name} contract\n */\n` +
    `export const ${name}Bytecode = "${artifact.bytecode}"\n\n` +
    `/**\n * Deployed bytecode for the ${name} contract\n */\n` +
    `export const ${name}DeployedBytecode = "${artifact.deployedBytecode}"\n`
  )
}

function main(): void {
  const base = arg('base')
  const version = arg('version')
  const root = process.cwd()
  const artifactsDir = path.join(root, 'artifacts', 'contracts')
  if (!fs.existsSync(artifactsDir))
    throw new Error('no artifacts: run `yarn build` first')

  const outDir = path.join(root, 'build', `routes-ts-${version}`)
  fs.rmSync(outDir, { recursive: true, force: true })
  fs.mkdirSync(outDir, { recursive: true })

  execFileSync(
    'npm',
    ['pack', `${PACKAGE}@${base}`, '--pack-destination', outDir],
    {
      stdio: 'inherit',
    },
  )
  const baseTarball = fs
    .readdirSync(outDir)
    .find((file) => file.endsWith('.tgz'))
  if (!baseTarball)
    throw new Error(`npm pack did not produce ${PACKAGE}@${base}`)
  execFileSync('tar', ['xzf', baseTarball], { cwd: outDir })
  fs.rmSync(path.join(outDir, baseTarball))
  const pkgDir = path.join(outDir, 'package')

  // Generate sources for exactly the ABI files the base version ships.
  const srcDir = path.join(outDir, 'src')
  const regenerated: string[] = []
  for (const dir of ABI_DIRS) {
    const distDir = path.join(pkgDir, 'dist', 'abi', dir)
    fs.mkdirSync(path.join(srcDir, dir), { recursive: true })
    for (const file of fs.readdirSync(distDir)) {
      if (!file.endsWith('.js') || file === 'index.js') continue
      const name = file.replace(/\.js$/, '')
      fs.writeFileSync(
        path.join(srcDir, dir, `${name}.ts`),
        abiSource(findArtifact(artifactsDir, name)),
      )
      regenerated.push(`${dir}/${name}`)
    }
  }

  const tscOut = path.join(outDir, 'tsc-out')
  execFileSync(
    path.join(root, 'node_modules', '.bin', 'tsc'),
    [
      '--declaration',
      '--module',
      'commonjs',
      '--target',
      'es2020',
      '--skipLibCheck',
      '--rootDir',
      srcDir,
      '--outDir',
      tscOut,
      ...regenerated.map((entry) => path.join(srcDir, `${entry}.ts`)),
    ],
    { stdio: 'inherit' },
  )
  for (const entry of regenerated) {
    for (const ext of ['.js', '.d.ts']) {
      fs.copyFileSync(
        path.join(tscOut, `${entry}${ext}`),
        path.join(pkgDir, 'dist', 'abi', `${entry}${ext}`),
      )
    }
  }
  fs.rmSync(srcDir, { recursive: true })
  fs.rmSync(tscOut, { recursive: true })

  const pkgJsonPath = path.join(pkgDir, 'package.json')
  const pkgJson = JSON.parse(fs.readFileSync(pkgJsonPath, 'utf8'))
  pkgJson.version = version
  fs.writeFileSync(pkgJsonPath, `${JSON.stringify(pkgJson, null, 2)}\n`)

  execFileSync('npm', ['pack', '--pack-destination', outDir], {
    cwd: pkgDir,
    stdio: 'inherit',
  })
  const tarball = path.join(outDir, `eco-foundation-routes-ts-${version}.tgz`)
  const sha256 = createHash('sha256')
    .update(fs.readFileSync(tarball))
    .digest('hex')
  console.log(
    `regenerated ${regenerated.length} ABI files: ${regenerated.join(', ')}`,
  )
  console.log(`${tarball}\nsha256 ${sha256}`)
}

main()
