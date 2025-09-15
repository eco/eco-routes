/**
 * @file index.ts
 *
 * The main entry point and orchestrator for the eco-routes semantic-release plugin system.
 * This module exports all lifecycle hooks that integrate with semantic-release,
 * providing a complete automated release pipeline for smart contract projects.
 *
 * The plugin implements a comprehensive workflow that handles everything from
 * version determination to contract deployment, verification, and package publishing.
 * It ensures that all deployment addresses are consistent across chains and properly
 * packaged for consumption by client applications.
 *
 * Semantic Release Lifecycle Implementation:
 * 1. verifyConditions - Validates environment, credentials, and prerequisites
 * 2. analyzeCommits - Determines the next version (using semantic-release core)
 * 3. generateNotes - Creates release notes (using semantic-release core)
 * 4. version - Updates version information in Solidity files and package.json
 * 5. prepare - Builds, deploys contracts with deterministic addresses, verifies contracts
 * 6. publish - Publishes the packaged library to npm with proper versioning
 *
 * This plugin architecture allows for separation of concerns while maintaining
 * a coordinated release process that handles both on-chain (smart contracts) and
 * off-chain (npm package) components of the protocol in a single automated flow.
 */

import { prepare } from './sr-prepare'
import { verifyConditions } from './sr-verify-conditions'
import { version } from './sr-version'
import { publish } from './sr-publish'

// Export functions for each semantic-release lifecycle hook using CommonJS format
// This format is required for semantic-release to properly load the plugin
module.exports = {
  // Plugin name helps with debugging and logging
  name: 'eco-routes-semantic-release-plugin',

  // Semantic Release configuration, including the versioning strategy
  // this means to rely on the npm version for versioning not the git tags
  npmPublish: true,

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
