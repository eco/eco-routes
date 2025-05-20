/**
 * @file eco-routes-local.ts
 *
 * Local development test runner for the semantic-release process lifecycle.
 * This utility enables developers to test and debug the complete release pipeline
 * without requiring a CI environment or the actual semantic-release tool.
 *
 * The module simulates the semantic-release process by manually invoking each
 * lifecycle step in the correct sequence with appropriate context. This allows
 * for rapid iteration and testing of release process changes without requiring
 * actual releases or complex CI setup.
 *
 * Key benefits:
 * - Test release process changes without impacting production releases
 * - Debug contract deployment issues in a controlled environment
 * - Validate environment variables and credentials before CI runs
 * - Test multi-chain deployment without publishing packages
 * - Simulate different version scenarios and release types
 * - Verify deterministic deployment consistency locally
 * - Accelerate development workflow for release pipeline changes
 *
 * The tool provides detailed logging to help diagnose issues in the release
 * process and ensure all components work correctly together.
 */

import { prepare, SemanticContext, SemanticPluginConfig } from './sr-prepare'
import { publish } from './sr-publish'
import { verifyConditions } from './sr-verify-conditions'
import { version } from './sr-version'

async function main() {
  // Create plugin config and context
  const pluginConfig: SemanticPluginConfig = {}
  const context: SemanticContext = {
    nextRelease: {
      version: '2.1.5',
      gitTag: 'v2.1.5',
      notes: 'Forcing publish',
      type: 'patch',
      channel: 'beta',
    },
    logger: {
      log: console.log,
      error: console.error,
      warn: console.warn,
    },
    cwd: process.cwd(),
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
    throw error
  }
}
main().catch((err) => {
  console.error('Error:', err)
})
