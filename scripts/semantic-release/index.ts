/**
 * @file index.ts
 *
 * Main entry point for the eco-routes semantic-release plugin.
 * Exports all lifecycle hooks that this plugin implements.
 *
 * Semantic Release Lifecycle Order:
 * 1. verifyConditions - validate environment and versions
 * 2. analyzeCommits - determine next version (built-in to semantic-release)
 * 3. verifyRelease - additional verification (optional, not implemented here)
 * 4. generateNotes - create release notes (built-in to semantic-release)
 * 5. version - update version information in Solidity files and package.json
 * 6. prepare - build, deploy contracts using deterministic addresses, verify contracts
 * 7. publish - publish the packaged library to npm
 *
 * This plugin enables automated versioning, contract deployment, and publishing
 * as part of a continuous delivery pipeline for the Eco Routes protocol.
 */

import { prepare } from './sr-prepare'
import { verifyConditions } from './sr-verify-conditions'
import { version } from './sr-version'
import { publish } from './sr-publish'

// Export functions for each semantic-release lifecycle hook
export default {
  // First step: verify all conditions are met for a release
  verifyConditions,

  // Version step: update version info in Solidity files and package.json
  // This runs after analyzeCommits and before prepare
  version,

  // Prepare step: deploy contracts and build package
  prepare,

  // Publish step: publish the built package to npm
  publish,

  // Additional hooks can be added later:
  // success, fail, etc.
}
