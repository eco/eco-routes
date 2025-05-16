/**
 * @file sr-singleton-factory.ts
 *
 * Handles the deployment of the canonical EIP-2470 Singleton Factory contract.
 * This module is a critical prerequisite for deterministic contract deployment
 * across multiple EVM chains during the semantic release process.
 *
 * The Singleton Factory is a standard contract deployed to the same address
 * (0xce0042B868300000d44A59004Da54A005ffdcf9f) on all EVM chains using a
 * specific private key and nonce. It provides a CREATE2 mechanism that enables
 * the deterministic deployment of contracts with consistent addresses across
 * all chains that support the EVM.
 *
 * This implementation:
 * - Verifies if the factory is already deployed on each target chain
 * - Deploys the factory using the canonical deployment process if not present
 * - Handles the specific gas parameters needed for different networks
 * - Ensures the factory is available for subsequent contract deployments
 * - Integrates with the semantic-release workflow to prevent deployment failures
 *
 * The presence of this factory is essential for the cross-chain consistency
 * that the eco-routes protocol relies on for its operation.
 */

import path from 'path'
import fs from 'fs'
import { SemanticContext } from './sr-prepare'
import { validateEnvVariables } from '../utils/envUtils'
import { executeProcess } from '../utils/processUtils'
import { PATHS } from './constants'

/**
 * Deploys the EIP-2470 Singleton Factory across all configured chains.
 * This function executes the deploySingletonFactory.sh script and throws if the script fails.
 *
 * @param context Semantic release context
 * @throws Error if the deployment script fails or required environment variables are missing
 */
export async function deploySingletonFactory(
  context: SemanticContext,
): Promise<void> {
  const { logger, cwd } = context

  // Check for required environment variables
  validateEnvVariables()

  // Path to the deployment script
  const deployScriptPath = path.join(cwd, PATHS.SINGLETON_FACTORY_DEPLOY_SCRIPT)

  // Check if the script exists
  if (!fs.existsSync(deployScriptPath)) {
    throw new Error(`Deployment script not found at ${deployScriptPath}`)
  }

  logger.log('Deploying EIP-2470 Singleton Factory...')

  try {
    // Execute the deployment script
    const exitCode = await executeProcess(
      deployScriptPath,
      [],
      process.env,
      cwd,
    )

    if (exitCode !== 0) {
      throw new Error(
        `Singleton Factory deployment failed with exit code ${exitCode}`,
      )
    }

    logger.log(
      '✅ EIP-2470 Singleton Factory deployment completed successfully',
    )
  } catch (error: any) {
    logger.error(`Singleton Factory deployment failed: ${error.message}`)
    throw error
  }
}
