import path from 'path'
import * as fs from 'node:fs'
import { spawn } from 'child_process'
import _ from 'lodash'
import { keccak256, toHex } from 'viem'
import { ProtocolVersion } from '../viem_deploy/ProtocolVersion'
import { addressesToCVS } from './csv'
import { transformAddresses } from './addresses'

export const deployScriptPath = path.join(__dirname, '../MultiDeploy.sh')
export const verifyScriptPath = path.join(__dirname, '../Verify.sh')

export const deployedContractFilePath = path.join(
  __dirname,
  `../../build/deployAddresses.json`,
)
export const deployFilePath = path.join(__dirname, '../../out/deployProd.csv')
export const deployPreprodFilePath = path.join(
  __dirname,
  '../../out/deployPreprod.csv',
)

async function main() {
  const pv = new ProtocolVersion()

  // Deploy contracts based on the major and minor versions
  const version = `${pv.version.major}.${pv.version.minor}`

  // Calculate hash from version
  const rootSalt = keccak256(toHex(version))

  // Calculate hash from version for preprod
  const preprodRootSalt = keccak256(toHex(`${version}-preprod`))

  // Deploy production contracts
  await deployContracts(rootSalt, deployFilePath)
  await verifyContracts(deployFilePath)

  // Deploy pre-production contracts
  await deployContracts(preprodRootSalt, deployPreprodFilePath)
  await verifyContracts(deployPreprodFilePath)

  const prodContracts = getDeployFile(deployFilePath)
  const preprodContracts = getDeployFile(deployPreprodFilePath, '-pre')

  const contracts = { ...prodContracts, ...preprodContracts }

  fs.writeFileSync(deployedContractFilePath, JSON.stringify(contracts, null, 2))

  transformAddresses()
  addressesToCVS()
}

function deployContracts(salt: string, deployFilePath: string) {
  return new Promise<void>((resolve, reject) => {
    const deployProcess = spawn(deployScriptPath, [], {
      env: { ...process.env, DEPLOY_FILE: deployFilePath, SALT: salt }, // Merge current env with custom SALT
      stdio: 'inherit', // Inherit console output (stdout, stderr)
      shell: true, // Ensures script execution compatibility
    })

    deployProcess.on('close', (code: number) => {
      console.log(`🔄 MultiDeploy.sh exited with code ${code}`)
      if (code !== 0) {
        console.error('❌ Deployment failed!')
        reject(code)
      }
      resolve()
    })
  })
}

function verifyContracts(deployFilePath: string) {
  return new Promise<void>((resolve, reject) => {
    const deployProcess = spawn(verifyScriptPath, [], {
      env: { ...process.env, DEPLOY_FILE: deployFilePath }, // Merge current env with custom SALT
      stdio: 'inherit', // Inherit console output (stdout, stderr)
      shell: true, // Ensures script execution compatibility
    })

    deployProcess.on('close', (code: number) => {
      console.log(`🔄 Verify.sh exited with code ${code}`)
      if (code !== 0) {
        console.error('❌ Verification failed!')
        reject(code)
      }
      resolve()
    })
  })
}

function getDeployFile(path: string, postfix: string = '') {
  const file = fs.readFileSync(path, 'utf-8')
  const contracts = file
    .split('\n')
    .map((line) => line.trim()) // Remove spaces
    .filter((line) => line.length) // Skip empty lines
    .map((line) => {
      // 10,0x513C9998Ebe2cC3539f056c6E46281c30972b183,contracts/IntentSource.sol:IntentSource,0x
      const [chainId, address, contractPath] = line.split(',')
      const [, contractName] = contractPath.split(':')
      return {
        address,
        name: contractName,
        chainId: parseInt(chainId),
      }
    })

  const contractGroupedByChain = _.groupBy(contracts, 'chainId')

  return Object.fromEntries(
    Object.entries(contractGroupedByChain).map(([chainId, v]) => {
      const names = _.map(v, 'name')
      const addresses = _.map(v, 'address')
      const contracts = _.zipObject(names, addresses)
      return [chainId + postfix, contracts]
    }),
  )
}

main().catch((err) => {
  console.error('Error:', err)
})
