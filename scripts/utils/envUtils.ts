/**
 * @file envUtils.ts
 *
 * Utility functions for environment variable management in deployment scripts.
 *
 * These utilities help validate that required environment variables are present
 * before attempting deployment operations, preventing cryptic failures or
 * misconfigurations. This is especially important for sensitive operations
 * like contract deployments that interact with blockchain networks.
 *
 * Key features:
 * - Environment variable validation
 * - Support for required and optional variables
 * - Specialized handling for deployment-related variables
 * - Clear error messages for missing variables
 */

import { ENV_VARS_REQUIRED } from '../semantic-release/constants'

/**
 * Validates that required environment variables are set
 *
 * @param envVars Array of required environment variable names
 * @throws Error if any required environment variable is not set
 */
export function validateEnvVariables(
  envVars: string[] = ENV_VARS_REQUIRED,
): void {
  for (const envVar of envVars) {
    if (!process.env[envVar]) {
      throw new Error(`Required environment variable ${envVar} is not set`)
    }
  }
}
