import { Hex } from 'viem'
import { promises as fs } from 'fs'
import * as path from 'path'

const ETHERSCAN_V2_API_URL = 'https://api.etherscan.io/v2/api'
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY as Hex
const DEPLOY_WAIT_TIME_MS = 60000 // 1 minute to wait for the contract bytecode to register on etherscan
const OUTPUT_DIR = path.join(__dirname, '../../artifacts/build-info')
export type VerifyContractType = {
  chainId: number
  codeformat: 'solidity-standard-json-input' | 'solidity-single-file'
  constructorArguements: string
  contractname: string
  contractaddress: Hex
  contractFilePath: string
}

export async function waitForSource(
  timeMs: number,
  getter: () => Promise<any>,
) {
  const start = Date.now()
  let res
  let a = 0
  while (Date.now() - start < timeMs) {
    console.log('Waiting for source...', a++)
    try {
      res = await getter()
      if (
        res.message === 'OK' &&
        res.result &&
        res.result[0] &&
        res.result[0].contractAddress
      ) {
        return res
      }
    } catch (e) {
      console.error(e)
    }
    await new Promise((resolve) => setTimeout(resolve, 5000))
  }
  return res
}

export async function getContractCreation(
  chainId: number,
  address: Hex,
): Promise<any> {
  const urlparam = {
    chainid: `${chainId}`,
    module: 'contract',
    action: 'getcontractcreation',
    contractaddresses: address,
    apikey: ETHERSCAN_API_KEY,
  }
  const addParams = new URLSearchParams(urlparam).toString()
  const url = ETHERSCAN_V2_API_URL + '?' + addParams
  const result = await fetch(url, {
    method: 'GET',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded;charset=utf-8',
    },
  })
  const res = await result.json()
  console.log(res)
  return res
}

export async function verifyContract(ver: VerifyContractType) {
  if (!ETHERSCAN_API_KEY) {
    throw new Error('ETHERSCAN_API_KEY not found')
  }
  await waitForSource(
    DEPLOY_WAIT_TIME_MS,
    async () => await getContractCreation(ver.chainId, ver.contractaddress),
  )
  console.log('Current directory:', __dirname)
  console.log('Artifact Output directory:', OUTPUT_DIR)
  const outputData = await readOutputFile()

  const metadata = JSON.parse(
    outputData.output.contracts[ver.contractFilePath][ver.contractname]
      .metadata,
  )
  const version = `v${metadata.compiler.version}`
  const target = Object.entries(metadata.settings.compilationTarget)[0].join(
    ':',
  )
  const sources = Object.entries(outputData.input.sources).reduce(
    (acc, [key, value]) => {
      acc[key as string] = { content: (value as any).content }
      return acc
    },
    {} as Record<string, { content: string }>,
  )

  const args = ver.constructorArguements
  console.log(target)
  console.log(version)
  console.log(metadata.settings)
  console.log(Object.keys(sources).length)
  console.log('Args length: ', args.length)
  const standardJson = {
    language: metadata.language,
    sources,
    settings: {
      viaIR: metadata.settings.viaIR,
      optimizer: metadata.settings.optimizer,
      evmVersion: metadata.settings.evmVersion,
      remappings: metadata.settings.remappings,
      libraries: metadata.settings.libraries,
    },
  }

  const body = {
    chainId: `${ver.chainId}`,
    contractaddress: ver.contractaddress,
    sourceCode: JSON.stringify(standardJson),
    codeformat: 'solidity-standard-json-input',
    contractname: target,
    compilerversion: version,
    constructorArguements: args,
  }

  const str = new URLSearchParams(body).toString()
  // console.log(str)
  try {
    const urlparam = {
      chainid: `${ver.chainId}`,
      module: 'contract',
      action: 'verifysourcecode',
      apikey: ETHERSCAN_API_KEY,
    }
    const addParams = new URLSearchParams(urlparam).toString()
    const url = ETHERSCAN_V2_API_URL + '?' + addParams
    const result = await fetch(url, {
      method: 'POST',
      body: str,
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded;charset=utf-8',
      },
    })
    const res = await result.json()
    console.log(res)

    const guid = res.result

    await checkVerifyStatus(ver.chainId, guid)
  } catch (e) {
    console.error(e)
  }
}

export async function checkVerifyStatus(chainId: number, guid: string) {
  try {
    const urlparam = {
      chainid: `${chainId}`,
      module: 'contract',
      action: 'checkverifystatus',
      guid,
      apikey: ETHERSCAN_API_KEY,
    }
    const addParams = new URLSearchParams(urlparam).toString()
    const url = ETHERSCAN_V2_API_URL + '?' + addParams
    const result = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded;charset=utf-8',
      },
    })
    const res = await result.json()

    console.log(res)
  } catch (e) {
    console.error(e)
  }
}

async function readOutputFile(): Promise<any> {
  const filePath = await getFirstJsonFile()
  if (!filePath) {
    throw new Error('No JSON file found in directory')
  }
  try {
    const data = await fs.readFile(filePath, 'utf-8')
    return JSON.parse(data)
  } catch (error) {
    console.error('Error reading JSON file:', error)
    throw error
  }
}

async function getFirstJsonFile(): Promise<string | null> {
  try {
    const files = await fs.readdir(OUTPUT_DIR)
    for (const file of files) {
      if (path.extname(file) === '.json') {
        return path.join(OUTPUT_DIR, file)
      }
    }
    return null
  } catch (error) {
    console.error('Error reading directory:', error)
    throw error
  }
}
