/**
 * @file eco-routes-local.ts
 *
 * Local test runner for the semantic-release process
 * Allows testing the full semantic-release lifecycle locally without requiring
 * the actual semantic-release tool or CI environment.
 *
 * This is useful for:  
 * - Testing changes to the release process
 * - Debugging release issues
 * - Validating environment setup
 * - Testing contract deployment without publishing
 */

import { prepare, SemanticContext, SemanticPluginConfig } from './sr-prepare'
import { verifyConditions } from './sr-verify-conditions'
import { version } from './sr-version'
import { publish } from './sr-publish'

async function main() {
  // Create plugin config and context
  const pluginConfig: SemanticPluginConfig = {}
  const context: SemanticContext = {
    nextRelease: { version: '0.0.5', gitTag: 'v0.0.5', notes: 'Test release', type: 'patch' },
    logger: {
      log: console.log,
      error: console.error,
      warn: console.warn,
    },
    cwd: process.cwd()
  }

  // Simulate the semantic-release lifecycle
  try {
    // 1. First verify conditions
    console.log('--- Starting verifyConditions phase ---')
    await verifyConditions(pluginConfig, context)

    // 2. Run version update phase
    console.log('\n--- Starting version phase ---')
    await version(pluginConfig, context)

    // 3. Then run prepare phase (build the solidity files, deploy contracts, verify contracts)
    console.log('\n--- Starting prepare phase ---')
    await prepare(pluginConfig, context)

    // 4. Finally run publish phase (publish to npm)
    console.log('\n--- Starting publish phase ---')
    const result = await publish(pluginConfig, context)

    console.log('\n✅ Semantic release simulation completed successfully')
    return result
  } catch (error) {
    console.error('\n❌ Semantic release simulation failed:')
    console.error((error as Error).message)
    process.exit(1)
  }
}
main().catch((err) => {
  console.error('Error:', err)
})
