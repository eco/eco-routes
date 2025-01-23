import * as fs from 'fs'
import * as path from 'path'
import { createFile, getJsonFromFile } from '../deploy/addresses'
import { pick } from 'lodash'

export const buildFolder = 'build'
export const tsBuildFolder = 'buildTs'
const packageJsonPath = path.join(__dirname, '../../package.json')
const outputPath = path.join(__dirname, `../../${buildFolder}/package.json`)
const outputTsPath = path.join(__dirname, `../../${tsBuildFolder}/package.json`)

export function generateBuildPckJson() {
  console.log('start package json generation')
  fs.readFile(packageJsonPath, 'utf8', (err, data) => {
    if (err) {
      console.error('Error reading package.json:', err)
      return
    }

    const packageJson = JSON.parse(data)
    // delete packageJson.dependencies
    delete packageJson.devDependencies
    delete packageJson.scripts
    delete packageJson.files
    delete packageJson.engines

    fs.writeFile(
      outputPath,
      JSON.stringify(packageJson, null, 2),
      'utf8',
      (err) => {
        if (err) {
          console.error('Error writing package.json:', err)
          return
        }

        console.log('package.json has been created successfully.')
      },
    )
  })
}

export function packageBuildTs() {
  const original = getJsonFromFile(outputPath) as any
  original.name = original.name + '-ts'
  const keepDeps = pick(original.dependencies, ['viem'])
  original.dependencies = keepDeps
  createFile(outputTsPath)
  fs.writeFileSync(outputTsPath, JSON.stringify(original, null, 2), 'utf8')
}
