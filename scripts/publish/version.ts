import core from '@actions/core'
import { ProtocolVersion } from '../viem_deploy/ProtocolVersion'

async function main() {
  const pv = new ProtocolVersion()
  pv.updateProjectVersion()
  // await pv.getDeployChains()
}

main()
  .then(() => {})
  .catch((err) => {
    console.error('Error:', err)
    core.setFailed(err.message)
  })
