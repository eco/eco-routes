# Polymer E2E Test Guide

## Prerequisites

Before running the end-to-end tests, ensure you have the following environment variables set in your shell:

```bash
export ALCHEMY_API_KEY="your_alchemy_api_key"
export BASE_SCAN_API_KEY="your_base_scan_api_key"
export OPTIMISM_SCAN_API_KEY="your_optimism_scan_api_key"
export DEPLOYER_PRIVATE_KEY="your_deployer_private_key"
export POLYMER_API_URL="your_polymer_api_url"
export POLYMER_API_KEY="your_polymer_api_key"
```

You can set these variables by creating a `.env` file and sourcing it:

```bash
source .env
```

⚠️ **WARNING**: This project requires Node.js v22.14.0. Use `nvm install 22.14.0` to install the correct version. Other Node.js versions may cause issues.

## Deployment Steps

1. First, compile the contracts from the root directory using the instructions in the [README](../README.md).

2. From the project root, make the deployment script executable:
   ```bash
   chmod +x scripts/polymer/deploy.sh
   ```

3. From the project root, run the deployment script:
   ```bash
   ./scripts/polymer/deploy.sh
   ```
   The script will prompt you to choose between:
   1) Testnets (Optimism Sepolia and Base Sepolia)
   2) Mainnets (Optimism and Base)

   Select option 1 for testnet deployment or option 2 for mainnet deployment. You will need a wallet with ETH and USDC on either Optimism and Base (or their respective Sepolia testnets) to run the end-to-end tests.

   See https://faucet.circle.com/ for testnet USDC. Pray to God if you need testnet ETH.

   This will deploy the contracts and output a `deployed.json` file containing the deployed contract addresses for:
   - Optimism Intent Source
   - Optimism Inbox
   - Optimism Prover
   - Base Intent Source
   - Base Inbox
   - Base Prover

## Running End-to-End Tests

After successful deployment, you can run the end-to-end tests using (replace testnet with mainnet to run on mainnet):

```bash
npx ts-node scripts/polymer/polymerE2E.ts testnet 
```

This will validate the deployment and test the cross-chain messaging functionality between Base and Optimism. You will need a wallet with 5 USDC on either Optimism or Base (or their respective Sepolia testnets) to run the end-to-end tests.

## Running Batch Tests

To run the batch tests, use the following command:

```bash
npx ts-node scripts/polymer/polymerE2EBatch.ts testnet
```

This will validate the deployment and test the batch proof functionality between Base and Optimism. You can adjust the batch size, intent usdc amount and reward amount by changing the `batchSize`, `usdcAmount` and `usdcRewardAmount` variables in the script.

## Troubleshooting

- Ensure all environment variables are properly set and sourced
- Check that the contracts are compiled successfully before deployment
- Verify you have sufficient funds in the deployer account for both Base and Optimism networks
- Make sure your API keys have sufficient rate limits for the deployment process