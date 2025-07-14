const fs = require('fs')
const path = require('path')

// Function to update test files with new signatures
function updateTestFile(filePath) {
  let content = fs.readFileSync(filePath, 'utf8')
  let updated = false

  // Update publish calls to include routeHash
  // Pattern: .publish(intent) -> .publish(intent, routeHash)
  content = content.replace(
    /\.publish\(([a-zA-Z]+Intent)\)/g,
    (match, intentVar) => {
      updated = true
      // Insert code to calculate routeHash before the publish call
      return `.getIntentHash(${intentVar})
      const routeHash = hashes[1]
      const tx = await intentSource.connect(creator).publish(${intentVar}, routeHash)`
    },
  )

  // Update fund calls to new parameter order
  // Pattern: .fund(destination, routeHash, reward, allowPartial) -> .fund(destination, reward, routeHash, allowPartial)
  content = content.replace(
    /\.fund\(([^,]+),\s*([^,]+),\s*([^,]+),\s*([^)]+)\)/g,
    (match, dest, routeHash, reward, allowPartial) => {
      updated = true
      return `.fund(${dest}, ${reward}, ${routeHash}, ${allowPartial})`
    },
  )

  // Update withdraw calls to new parameter order
  // Pattern: .withdraw(destination, routeHash, reward) -> .withdraw(destination, reward, routeHash)
  content = content.replace(
    /\.withdraw\(([^,]+),\s*([^,]+),\s*([^)]+)\)/g,
    (match, dest, routeHash, reward) => {
      updated = true
      return `.withdraw(${dest}, ${reward}, ${routeHash})`
    },
  )

  // Update refund calls to new parameter order
  // Pattern: .refund(destination, routeHash, reward) -> .refund(destination, reward, routeHash)
  content = content.replace(
    /\.refund\(([^,]+),\s*([^,]+),\s*([^)]+)\)/g,
    (match, dest, routeHash, reward) => {
      updated = true
      return `.refund(${dest}, ${reward}, ${routeHash})`
    },
  )

  // Update fulfill calls to new signature
  // Pattern: fulfill(sourceChainId, route, rewardHash, claimant, expectedHash, prover)
  // -> fulfill(intentHash, route, rewardHash, claimant)
  content = content.replace(
    /\.fulfill\(\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^)]+)\)/g,
    (
      match,
      sourceChainId,
      route,
      rewardHash,
      claimant,
      expectedHash,
      prover,
    ) => {
      updated = true
      return `.fulfill(${expectedHash}, ${route}, ${rewardHash}, ${claimant})`
    },
  )

  // Update initiateProving to prove
  content = content.replace(/initiateProving/g, 'prove')

  if (updated) {
    fs.writeFileSync(filePath, content, 'utf8')
    console.log(`Updated: ${filePath}`)
  }
}

// Find all test files
const testDir = path.join(__dirname, '..', 'test')
const testFiles = fs
  .readdirSync(testDir)
  .filter((file) => file.endsWith('.spec.ts'))
  .map((file) => path.join(testDir, file))

// Update each test file
testFiles.forEach(updateTestFile)

console.log('Test file updates complete')
