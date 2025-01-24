// publish --tag beta --access public # --provenance --access public

import core from '@actions/core'
import { execCMD } from '../utils'
import { ProtocolVersion, PublishTag } from '../viem_deploy/ProtocolVersion'
import { buildFolder, packageBuildTs, tsBuildFolder } from './create_package'

type PublishOps = {
  tag: PublishTag
  cwd: string
}

const MainBetaPublishOps: PublishOps = { tag: 'beta', cwd: buildFolder }
const TsBetaPublishOps: PublishOps = { tag: 'beta', cwd: tsBuildFolder }

async function publish(ops: any = MainBetaPublishOps) {
  await execCMD(`echo starting yarn publish`, ops)
  await execCMD(`"pwd"  pwd`, ops)
  await execCMD(`echo NPM publish: `, JSON.stringify(ops))
  await execCMD(`echo GITHUB_ACTION is $GITHUB_ACTION`, ops)
  await execCMD(`yarn publish --tag ${ops.tag} --access public`, ops)
}

async function publishTs(ops: any = TsBetaPublishOps) {
  await execCMD(`cp -r build ${ops.cwd}`)
  await execCMD(`rimraf ${ops.cwd}/src`)
  packageBuildTs()
  await publish(ops)
}

async function main() {
  const pv = new ProtocolVersion()
  const tag = pv.getReleaseTag()
  await publish({ tag, cwd: 'build' })
  await publishTs({ tag, cwd: 'buildTs' })
}

main()
  .then(() => {})
  .catch((err) => {
    console.error('Error:', err)
    core.setFailed(err.message)
  })
