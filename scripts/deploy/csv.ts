import * as fs from 'fs'
import { csvFilePath, jsonFilePath } from './addresses'

// Function to append data to the CSV
function appendToCSV(filePath: string, data: Record<string, any>) {
  const rows = Object.entries(data).map(([key, values]) => {
    const { Prover, IntentSource, Inbox, HyperProver, MetaProver } = values
    return `${key},${Prover},${IntentSource},${Inbox},${HyperProver},${MetaProver}`
  })
  if (!fs.existsSync(filePath)) {
    fs.writeFileSync(
      filePath,
      'Chain,Prover,IntentSource,Inbox,HyperProver\n',
      'utf8',
    )
  }
  fs.appendFileSync(filePath, rows.join('\n') + '\n', 'utf8')
}

// Read JSON file and append its contents to the CSV
export function addressesToCVS() {
  if (!fs.existsSync(jsonFilePath)) {
    console.error('JSON file not found:', jsonFilePath)
    return
  }

  const jsonData = JSON.parse(fs.readFileSync(jsonFilePath, 'utf8'))

  if (typeof jsonData !== 'object' || Array.isArray(jsonData)) {
    console.error('Invalid JSON data format. Expected an object.')
    return
  }

  appendToCSV(csvFilePath, jsonData)
  console.log('Data appended successfully from JSON!')
}
