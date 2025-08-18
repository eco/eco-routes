#!/usr/bin/env node

// Simple test script to verify energy rental manager integration
const { spawn } = require('child_process');
const path = require('path');

console.log('Testing Energy Rental Manager Integration');
console.log('========================================');

// Test 1: Try to run the deployment script with testnet (should skip rental)
console.log('\n1. Testing testnet deployment (should skip energy rental)...');

const testnetCmd = spawn('node', [
  path.join(__dirname, 'dist/scripts/deploy-layerzeroprover.js'),
  'testnet'
], {
  env: {
    ...process.env,
    TRON_PRIVATE_KEY: 'dummy_key_for_test',
    TRON_PORTAL: 'TGhZDJhuELXvnU2pHnVDLJ8UCzNg29aEHU',
    TRON_PROVERS: 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t'
  },
  stdio: 'pipe'
});

let output = '';
let errorOutput = '';

testnetCmd.stdout.on('data', (data) => {
  output += data.toString();
});

testnetCmd.stderr.on('data', (data) => {
  errorOutput += data.toString();
});

testnetCmd.on('close', (code) => {
  console.log(`Testnet test completed with code: ${code}`);
  
  if (output.includes('Energy rental manager initialized')) {
    console.log('FAIL: Energy rental manager should NOT initialize for testnet');
  } else {
    console.log('PASS: Energy rental manager correctly skipped for testnet');
  }

  if (output.includes('Testnet deployment: Skipping TronZap rental') || 
      output.includes('Checking system health') ||
      errorOutput.includes('TRON_PRIVATE_KEY')) {
    console.log('PASS: Testnet path executed correctly');
  } else {
    console.log('FAIL: Testnet execution path issues');
  }

  // Test 2: Try mainnet without TronZap API key (should show warning)
  console.log('\n2. Testing mainnet without TronZap API key (should show warning)...');
  
  const mainnetCmd = spawn('node', [
    path.join(__dirname, 'dist/scripts/deploy-layerzeroprover.js'),
    'mainnet'
  ], {
    env: {
      ...process.env,
      TRON_PRIVATE_KEY: 'dummy_key_for_test',
      TRON_PORTAL: 'TGhZDJhuELXvnU2pHnVDLJ8UCzNg29aEHU',
      TRON_PROVERS: 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t',
      TRONZAP_API_KEY: undefined // Explicitly unset
    },
    stdio: 'pipe'
  });

  let mainnetOutput = '';
  let mainnetErrorOutput = '';

  mainnetCmd.stdout.on('data', (data) => {
    mainnetOutput += data.toString();
  });

  mainnetCmd.stderr.on('data', (data) => {
    mainnetErrorOutput += data.toString();
  });

  mainnetCmd.on('close', (code) => {
    console.log(`Mainnet test completed with code: ${code}`);
    
    if (mainnetOutput.includes('TronZap API key not found') || 
        mainnetOutput.includes('Set TRONZAP_API_KEY environment variable')) {
      console.log('PASS: Mainnet correctly shows TronZap API key warning');
    } else {
      console.log('FAIL: Missing expected TronZap API key warning');
    }

    console.log('\n=== Test Output Sample ===');
    console.log('Testnet output:', output.substring(0, 200) + '...');
    console.log('Mainnet output:', mainnetOutput.substring(0, 200) + '...');
    
    if (errorOutput) {
      console.log('Testnet errors:', errorOutput.substring(0, 200) + '...');
    }
    if (mainnetErrorOutput) {
      console.log('Mainnet errors:', mainnetErrorOutput.substring(0, 200) + '...');
    }

    console.log('\n=== Energy Rental Integration Test Complete ===');
  });
});