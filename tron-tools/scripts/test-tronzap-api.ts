import { TronZapClient } from '../src/rental/TronZapClient'
import { logger } from '../src/utils/logger'
import * as dotenv from 'dotenv'
import * as path from 'path'

// Load environment variables
dotenv.config({ path: path.join(__dirname, '../../.env') })

/**
 * Test TronZap API endpoints to determine correct format and functionality
 */
async function testTronZapAPI() {
  console.log('TronZap API Endpoint Testing')
  console.log('============================')
  console.log('')

  try {
    // Initialize TronZap client
    const client = new TronZapClient()
    console.log('✓ TronZap client initialized successfully')
    console.log('  Token:', process.env.TRONZAP_API_TOKEN?.substring(0, 8) + '...')
    console.log('  Secret:', process.env.TRONZAP_API_SECRET ? '***configured***' : 'MISSING')
    console.log('')

    // Test 1: Get services to see available service IDs
    console.log('Test 1: Getting available services...')
    console.log('-------------------------------------')
    try {
      // Try to get services with proper authentication
      const axios = require('axios')
      const requestBody = '{}'
      const signature = require('crypto').createHash('sha256').update(requestBody + (process.env.TRONZAP_API_SECRET || '')).digest('hex')
      
      const response = await axios.post('https://api.tronzap.com/v1/services', {}, {
        headers: {
          'Authorization': `Bearer ${process.env.TRONZAP_API_TOKEN}`,
          'X-Signature': signature,
          'Content-Type': 'application/json'
        }
      })
      
      console.log('✓ SUCCESS: /v1/services worked!')
      console.log(`  Services available:`)
      if (response.data.services) {
        response.data.services.forEach((service: any) => {
          console.log(`    ID: ${service.id}, Name: ${service.name}, Price: ${service.price} TRX`)
        })
      } else {
        console.log(`  Raw response: ${JSON.stringify(response.data, null, 2)}`)
      }
    } catch (error: any) {
      console.log('✗ FAILED: /v1/services')
      console.log(`  Error: ${error.message}`)
      console.log(`  Status: ${error.response?.status}`)
      console.log(`  Response: ${JSON.stringify(error.response?.data, null, 2)}`)
    }
    
    // Test 1b: Get rental prices (fallback)
    console.log('')
    console.log('Test 1b: Getting rental prices (fallback)...')
    console.log('---------------------------------------------')
    try {
      const prices = await client.getRentalPrices()
      console.log('✓ SUCCESS: getRentalPrices() worked!')
      console.log(`  Energy Price: ${prices.energy.pricePerUnit.toFixed(8)} TRX/unit`)
      console.log(`  Energy Min/Max: ${prices.energy.minAmount.toLocaleString()} - ${prices.energy.maxAmount.toLocaleString()}`)
      console.log(`  Bandwidth Price: ${prices.bandwidth.pricePerUnit.toFixed(8)} TRX/unit`)
      console.log(`  Bandwidth Min/Max: ${prices.bandwidth.minAmount.toLocaleString()} - ${prices.bandwidth.maxAmount.toLocaleString()}`)
      console.log(`  Timestamp: ${prices.timestamp.toISOString()}`)
    } catch (error: any) {
      console.log('✗ FAILED: getRentalPrices()')
      console.log(`  Error: ${error.message}`)
      console.log(`  Status: ${error.response?.status}`)
      console.log(`  Response: ${JSON.stringify(error.response?.data, null, 2)}`)
    }
    console.log('')

    // Test 2: Try energy rental with real deployer address  
    console.log('Test 2: Testing energy rental with real deployer address...')
    console.log('--------------------------------------------------------')
    const REAL_DEPLOYER_ADDRESS = 'TJJYsUz2F4fURzX2Rf4jDWDNdKf5Y86fnk' // Real deployer address from mainnet
    const DUMMY_ENERGY_AMOUNT = 100000
    
    try {
      const energyRental = await client.rentEnergy(DUMMY_ENERGY_AMOUNT, REAL_DEPLOYER_ADDRESS)
      if (energyRental.success) {
        console.log('✓ SUCCESS: rentEnergy() worked!')
        console.log(`  Transaction ID: ${energyRental.transactionId}`)
        console.log(`  Cost: ${energyRental.cost} TRX`)
        console.log(`  Expires: ${energyRental.expiresAt.toISOString()}`)
      } else {
        console.log('✗ FAILED: rentEnergy() - API rejected request')
        console.log(`  Error: ${energyRental.error}`)
      }
    } catch (error: any) {
      console.log('✗ FAILED: rentEnergy()')
      console.log(`  Error: ${error.message}`)
      console.log(`  Status: ${error.response?.status}`)
      console.log(`  Response: ${JSON.stringify(error.response?.data, null, 2)}`)
    }
    console.log('')

    // Test 3: Try bandwidth rental with dummy data (current endpoint: POST /v1/rental/bandwidth)
    console.log('Test 3: Testing bandwidth rental with dummy data...')
    console.log('--------------------------------------------------')
    const DUMMY_BANDWIDTH_AMOUNT = 10000
    
    try {
      const bandwidthRental = await client.rentBandwidth(DUMMY_BANDWIDTH_AMOUNT, REAL_DEPLOYER_ADDRESS)
      if (bandwidthRental.success) {
        console.log('✓ SUCCESS: rentBandwidth() worked!')
        console.log(`  Transaction ID: ${bandwidthRental.transactionId}`)
        console.log(`  Cost: ${bandwidthRental.cost} TRX`)
        console.log(`  Expires: ${bandwidthRental.expiresAt.toISOString()}`)
      } else {
        console.log('✗ FAILED: rentBandwidth() - API rejected request')
        console.log(`  Error: ${bandwidthRental.error}`)
      }
    } catch (error: any) {
      console.log('✗ FAILED: rentBandwidth()')
      console.log(`  Error: ${error.message}`)
      console.log(`  Status: ${error.response?.status}`)
      console.log(`  Response: ${JSON.stringify(error.response?.data, null, 2)}`)
    }
    console.log('')

    // Test 4: Test other potential endpoints
    console.log('Test 4: Exploring alternative endpoints...')
    console.log('------------------------------------------')
    
    // Test common endpoint variations
    const endpointsToTest = [
      { method: 'GET', path: '/services', description: 'GET services' },
      { method: 'GET', path: '/api/services', description: 'GET api/services' },
      { method: 'GET', path: '/v1/services', description: 'GET v1/services' },
      { method: 'POST', path: '/api/services', description: 'POST api/services' },
      { method: 'POST', path: '/v1/services', description: 'POST v1/services' },
      { method: 'GET', path: '/energy/prices', description: 'GET energy/prices' },
      { method: 'GET', path: '/api/energy/prices', description: 'GET api/energy/prices' },
      { method: 'GET', path: '/v1/energy/prices', description: 'GET v1/energy/prices' },
      { method: 'POST', path: '/energy', description: 'POST energy' },
      { method: 'POST', path: '/api/energy', description: 'POST api/energy' },
      { method: 'POST', path: '/v1/energy', description: 'POST v1/energy' },
      { method: 'GET', path: '/status', description: 'GET status' },
      { method: 'GET', path: '/health', description: 'GET health' },
    ]

    // Import axios directly to test endpoints
    const axios = require('axios')
    const baseURL = process.env.TRONZAP_API_URL || 'https://api.tronzap.com'
    
    for (const endpoint of endpointsToTest) {
      try {
        const config: any = {
          method: endpoint.method.toLowerCase(),
          url: `${baseURL}${endpoint.path}`,
          timeout: 10000,
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': 'Eco-TronTools/1.0.0',
            'X-API-TOKEN': process.env.TRONZAP_API_TOKEN
          }
        }

        if (endpoint.method === 'POST') {
          config.data = {}
          // Add signature for POST requests
          const requestBody = '{}'
          const signature = require('crypto').createHash('sha256').update(requestBody + (process.env.TRONZAP_API_SECRET || '')).digest('hex')
          config.headers['X-API-SIGNATURE'] = signature
        }

        const response = await axios(config)
        console.log(`✓ ${endpoint.description}: Status ${response.status}`)
        if (response.data) {
          console.log(`  Response keys: ${Object.keys(response.data).join(', ')}`)
        }
      } catch (error: any) {
        if (error.response) {
          console.log(`✗ ${endpoint.description}: Status ${error.response.status} - ${error.response.statusText}`)
        } else {
          console.log(`✗ ${endpoint.description}: ${error.message}`)
        }
      }
    }

    console.log('')
    console.log('Test Summary:')
    console.log('=============')
    console.log('Current issues identified:')
    console.log('- POST /services returns 404')
    console.log('- POST /energy-transaction returns 404')
    console.log('- POST /v1/rental/bandwidth returns 404')
    console.log('')
    console.log('Recommendations:')
    console.log('1. Check TronZap API documentation for correct endpoints')
    console.log('2. Verify API base URL is correct')
    console.log('3. Confirm authentication format (token + signature)')
    console.log('4. Test with actual TronZap support if endpoints remain unclear')

  } catch (error) {
    console.error('Test setup failed:', error)
    process.exit(1)
  }
}

// Run the test if this file is executed directly
if (require.main === module) {
  testTronZapAPI().catch(console.error)
}

export { testTronZapAPI }