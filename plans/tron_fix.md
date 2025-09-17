# TRON Deployment Refactor Plan

## Overview

Refactor the `scripts/tron-deploy.ts` file to be a cleaner, more maintainable deployment utility that uses version-based deployment tracking and simplified configuration.

## Current State Analysis

- `scripts/tron-deploy.ts` is a complex deployment script with many environment variables
- `deploys/tron.json` contains production and staging deployment addresses
- Salt utility exists in `scripts/utils/extract-salt.ts` for version-based salt generation

## Requirements

### 1. Version Integration

- **Objective**: Use the salt utility to extract version information
- **Implementation**:
  - Import `getBaseVersion` from `scripts/utils/extract-salt.ts`
  - Extract version from package.json or environment variable
  - Use base version (major.minor) for deployment tracking

### 2. Version-Based Deployment Files

- **Objective**: Generate deployment files based on version and network
- **File Format**: `deploys/<version>-<rpc-chain>.json`
- **Examples**:
  - `deploys/2.1-mainnet.json`
  - `deploys/2.1-shasta.json`
  - `deploys/2.1-nile.json`
- **Structure**:
  ```json
  {
    "production": {
      "portal": "TLWEMdEZKbtW4wibbzJdDhzxuc1mKsomfk",
      "polymerProver": "TY4WstRqmNqHWRCfmCoZdPhdEJ3LQEopYQ"
    },
    "staging": {
      "portal": "...",
      "polymerProver": "..."
    }
  }
  ```

### 3. Deployment Status Check

- **Objective**: Check if deployments exist before deploying new contracts
- **Logic**:
  - Load version-based deployment file
  - Check if `production.portal` and `production.polymerProver` are set
  - Check if `staging.portal` and `staging.polymerProver` are set
  - Only deploy missing contracts

### 4. Conditional Deployment Logic

- **Objective**: Deploy only what's missing
- **Implementation**:
  - If production portal missing → deploy portal to production
  - If production polymerProver missing → deploy polymerProver to production
  - If staging portal missing → deploy portal to staging
  - If staging polymerProver missing → deploy polymerProver to staging
  - Update deployment file after each successful deployment

### 5. Simplified Configuration

- **Objective**: Reduce environment variable dependencies
- **Required Environment Variables**:
  - `PRIVATE_KEY` - Deployment private key
  - `TRON_RPC_URL` or `TRON_SHASTA_RPC_URL` or `TRON_NILE_RPC_URL` - RPC endpoints
  - `CHAIN_DATA_URL` - For fetching polymer cross L2 prover data
- **Removed Dependencies**:
  - `PORTAL_CONTRACT` (use version-based file instead)
  - `POLYMER_PROVER_CONTRACT` (use version-based file instead)
  - `LAYERZERO_ENDPOINT` (not currently used)
  - `LAYERZERO_DELEGATE` (not currently used)
  - `DEPLOY_FILE` (use version-based naming)
  - Various prover arrays (simplified or removed)

## Implementation Plan

### Phase 1: Version Integration

1. Add version detection logic using package.json
2. Integrate `getBaseVersion` from extract-salt utility
3. Create network detection from RPC URL

### Phase 2: File Structure Update

1. Create version-based deployment file naming scheme
2. Add file existence and structure validation
3. Implement deployment status checking logic

### Phase 3: Deployment Logic Refactor

1. Remove unused LayerZero deployment logic
2. Simplify deployment context to only include necessary fields
3. Add conditional deployment based on missing contracts
4. Update file writing to use version-based files

### Phase 4: Configuration Cleanup

1. Remove unused environment variables
2. Simplify constructor to only use essential env vars
3. Update error handling and logging
4. Add validation for required environment variables

### Phase 5: Testing and Validation

1. Test with existing deployment files
2. Validate deployment process with missing contracts
3. Test version-based file generation
4. Ensure backward compatibility where needed

## Expected Outcomes

- Cleaner, more maintainable deployment script
- Version-based deployment tracking
- Reduced configuration complexity
- Better deployment state management
- Easier debugging and maintenance

## Breaking Changes

- Deployment file location changes from fixed `deploys/tron.json` to version-based files
- Environment variable requirements reduced
- Some deployment logic simplified (LayerZero support reduced)

## Migration Strategy

- Keep existing `deploys/tron.json` for reference
- New deployments will use version-based files
- Provide migration utility if needed to convert existing deployments
