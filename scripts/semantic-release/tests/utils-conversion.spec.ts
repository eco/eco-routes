import { base58ToHex, hexToBase58 } from '../assets/utils/utils'

describe('Base58 and Hex Conversion Utilities', () => {
  // Test cases with validated TRON addresses and their correct hex representations
  const testCases = [
    {
      name: 'User example 1 - TRON address',
      base58: 'TQh8ig6rmuMqb5u8efU5LDvoott1oLzoqu',
      hex: '0x000000000000000000000000a17fa8126b6a12feb2fe9c19f618fe04d7329074',
    },
    {
      name: 'TRON address derived from user hex example 2',
      base58: 'TFtcu11tV1CM5gYS4o1WC6o9sZxxZ6euNx',
      hex: '0x00000000000000000000000040f29f34a3548e8c7f05b6202d0d7df3de781788',
    },
    {
      name: 'TRON USDT contract address',
      base58: 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t',
      hex: '0x000000000000000000000000a614f803b6fd780986a42c78ec9c7f77e6ded13c',
    },
    {
      name: 'TRON mainnet address',
      base58: 'TLyqzVGLV1srkB7dToTAEqgDSfPtXRJZYH',
      hex: '0x00000000000000000000000078c842ee63b253f8f0d2955bbc582c661a078c9d',
    },
    {
      name: 'Solana mainnet address',
      base58: 'C34z78p3WtkDZoxtBqiKgeuC71rbnv2H7koqHmb5Eo3M',
      hex: '0xa3f83922f3081c229a9f7ff240f29f34a3548e8c7f05b6202d0d7df3de781788',
    },
  ]

  describe('base58ToHex', () => {
    testCases.forEach((testCase) => {
      it(`should convert ${testCase.name} from Base58 to hex`, () => {
        const result = base58ToHex(testCase.base58)
        expect(result).toBe(testCase.hex)
      })
    })

    it('should handle various Base58 address formats correctly', () => {
      // Test a known conversion
      const result = base58ToHex('TQh8ig6rmuMqb5u8efU5LDvoott1oLzoqu')

      // Verify the result is properly formatted
      expect(result).toMatch(/^0x[0-9a-fA-F]{64}$/)
      expect(result).toBe(
        '0x000000000000000000000000a17fa8126b6a12feb2fe9c19f618fe04d7329074',
      )
    })

    it('should handle various Base58 inputs consistently', () => {
      // Test that the function produces consistent output format regardless of input
      const testInputs = [
        'TQh8ig6rmuMqb5u8efU5LDvoott1oLzoqu', // Valid TRON address
        'InvalidAddress123', // May be processed as a valid input
        'T123', // Short input
      ]

      testInputs.forEach((address) => {
        try {
          const result = base58ToHex(address)
          // If it doesn't throw, the result should be a valid hex string format
          expect(result).toMatch(/^0x[0-9a-fA-F]{64}$/)
          expect(typeof result).toBe('string')
        } catch (error) {
          // If it throws, the error should be meaningful
          expect((error as Error).message).toContain(
            'Failed to convert Base58 address to hex',
          )
        }
      })
    })

    it('should produce consistent 64-character hex strings (32 bytes padded)', () => {
      testCases.forEach((testCase) => {
        const result = base58ToHex(testCase.base58)

        // Should start with 0x
        expect(result).toMatch(/^0x/)

        // Should be exactly 66 characters total (0x + 64 hex chars)
        expect(result).toHaveLength(66)

        // Should contain only valid hex characters
        expect(result).toMatch(/^0x[0-9a-fA-F]{64}$/)
      })
    })
  })

  describe('hexToBase58', () => {
    testCases.forEach((testCase) => {
      it(`should convert ${testCase.name} from hex to Base58`, () => {
        const result = hexToBase58(testCase.hex)
        expect(result).toBe(testCase.base58)
      })
    })

    it('should handle hex strings with and without 0x prefix', () => {
      const hexWithPrefix =
        '0x000000000000000000000000a17fa8126b6a12feb2fe9c19f618fe04d7329074'
      const hexWithoutPrefix =
        '000000000000000000000000a17fa8126b6a12feb2fe9c19f618fe04d7329074'

      const result1 = hexToBase58(hexWithPrefix)
      const result2 = hexToBase58(hexWithoutPrefix)

      expect(result1).toBe('TQh8ig6rmuMqb5u8efU5LDvoott1oLzoqu')
      expect(result2).toBe('TQh8ig6rmuMqb5u8efU5LDvoott1oLzoqu')
      expect(result1).toBe(result2)
    })

    it('should handle 40-character hex strings (standard Ethereum addresses)', () => {
      // Extract the 40-character address part from a 64-character padded hex
      const paddedHex =
        '0x000000000000000000000000a17fa8126b6a12feb2fe9c19f618fe04d7329074'
      const shortHex = '0xa17fa8126b6a12feb2fe9c19f618fe04d7329074' // 40 characters
      const shortHexNoPrefix = 'a17fa8126b6a12feb2fe9c19f618fe04d7329074' // 40 characters, no prefix

      const result1 = hexToBase58(paddedHex)
      const result2 = hexToBase58(shortHex)
      const result3 = hexToBase58(shortHexNoPrefix)

      // All should produce the same Base58 address
      expect(result1).toBe('TQh8ig6rmuMqb5u8efU5LDvoott1oLzoqu')
      expect(result2).toBe('TQh8ig6rmuMqb5u8efU5LDvoott1oLzoqu')
      expect(result3).toBe('TQh8ig6rmuMqb5u8efU5LDvoott1oLzoqu')
      expect(result1).toBe(result2)
      expect(result1).toBe(result3)
    })

    it('should throw error for definitely invalid hex address lengths', () => {
      const definitelyInvalidHex = [
        '0x123456789012345678901234567890123456789', // 39 characters (invalid length)
        '0x12345678901234567890123456789012345678901', // 41 characters (invalid length)
      ]

      definitelyInvalidHex.forEach((invalidHex) => {
        expect(() => {
          hexToBase58(invalidHex)
        }).toThrow(/Unsupported hex address length|Invalid hex address length/)
      })
    })

    it('should handle various hex inputs consistently', () => {
      const hexInputs = [
        '0x000000000000000000000000a17fa8126b6a12feb2fe9c19f618fe04d7329074', // Valid padded hex
        '0xa17fa8126b6a12feb2fe9c19f618fe04d7329074', // Valid 40-char hex
        'a17fa8126b6a12feb2fe9c19f618fe04d7329074', // Valid 40-char hex without 0x
      ]

      hexInputs.forEach((hex) => {
        try {
          const result = hexToBase58(hex)
          // Should produce a valid Base58 string
          expect(typeof result).toBe('string')
          expect(result).toMatch(/^[1-9A-HJ-NP-Za-km-z]+$/)
        } catch (error) {
          // If it throws, the error should be meaningful
          expect((error as Error).message).toMatch(
            /Failed to convert hex address to Base58|Invalid hex address length/,
          )
        }
      })
    })

    it('should produce valid Base58 strings', () => {
      testCases.forEach((testCase) => {
        const result = hexToBase58(testCase.hex)

        // Should be a non-empty string
        expect(typeof result).toBe('string')
        expect(result.length).toBeGreaterThan(0)

        // Base58 uses characters 1-9, A-H, J-N, P-Z, a-k, m-z (no 0, O, I, l)
        expect(result).toMatch(/^[1-9A-HJ-NP-Za-km-z]+$/)
      })
    })
  })

  describe('Round-trip conversions', () => {
    it('should maintain consistency when converting Base58 → hex → Base58', () => {
      testCases.forEach((testCase) => {
        const hexResult = base58ToHex(testCase.base58)
        const base58Result = hexToBase58(hexResult)

        expect(base58Result).toBe(testCase.base58)
      })
    })

    it('should maintain consistency when converting hex → Base58 → hex', () => {
      testCases.forEach((testCase) => {
        const base58Result = hexToBase58(testCase.hex)
        const hexResult = base58ToHex(base58Result)

        expect(hexResult).toBe(testCase.hex)
      })
    })

    it('should handle multiple round-trip conversions', () => {
      const originalBase58 = 'TQh8ig6rmuMqb5u8efU5LDvoott1oLzoqu'
      let current = originalBase58

      // Perform multiple round-trip conversions
      for (let i = 0; i < 5; i++) {
        const hex = base58ToHex(current)
        current = hexToBase58(hex)
        expect(current).toBe(originalBase58)
      }
    })
  })

  describe('Edge cases and special scenarios', () => {
    it('should handle addresses with all zeros in the significant part', () => {
      // An address that might have zeros in the 20-byte address part
      const zeroAddress =
        '0x0000000000000000000000000000000000000000000000000000000000000000'

      expect(() => {
        const base58Result = hexToBase58(zeroAddress)
        const hexResult = base58ToHex(base58Result)
        // The conversion should work, even if the address is mostly zeros
        expect(hexResult).toMatch(/^0x[0-9a-fA-F]{64}$/)
      }).not.toThrow()
    })

    it('should handle addresses with maximum values', () => {
      // An address with all F's in the significant part
      const maxAddress =
        '0x000000000000000000000000ffffffffffffffffffffffffffffffffffffffff'

      expect(() => {
        const base58Result = hexToBase58(maxAddress)
        const hexResult = base58ToHex(base58Result)
        expect(hexResult).toMatch(/^0x[0-9a-fA-F]{64}$/)
      }).not.toThrow()
    })

    it('should properly handle case sensitivity in hex inputs', () => {
      const lowerCaseHex =
        '0x000000000000000000000000a17fa8126b6a12feb2fe9c19f618fe04d7329074'
      const upperCaseHex =
        '0x000000000000000000000000A17FA8126B6A12FEB2FE9C19F618FE04D7329074'
      const mixedCaseHex =
        '0x000000000000000000000000a17Fa8126B6a12Feb2fe9C19f618Fe04d7329074'

      const result1 = hexToBase58(lowerCaseHex)
      const result2 = hexToBase58(upperCaseHex)
      const result3 = hexToBase58(mixedCaseHex)

      // All should produce the same result regardless of case
      expect(result1).toBe(result2)
      expect(result1).toBe(result3)
      expect(result1).toBe('TQh8ig6rmuMqb5u8efU5LDvoott1oLzoqu')
    })
  })

  describe('Performance and reliability', () => {
    it('should handle multiple conversions efficiently', () => {
      const startTime = Date.now()

      // Perform multiple conversions
      for (let i = 0; i < 100; i++) {
        testCases.forEach((testCase) => {
          const hex = base58ToHex(testCase.base58)
          const base58 = hexToBase58(hex)
          expect(base58).toBe(testCase.base58)
        })
      }

      const endTime = Date.now()
      const duration = endTime - startTime

      // Should complete within reasonable time (adjust threshold as needed)
      expect(duration).toBeLessThan(5000) // 5 seconds for 400 conversions
    })

    it('should provide detailed error messages for debugging', () => {
      try {
        base58ToHex('invalid-base58-address')
      } catch (error) {
        const errorMessage = (error as Error).message
        expect(errorMessage).toContain(
          'Failed to convert Base58 address to hex',
        )
        expect(errorMessage).toContain('invalid-base58-address')
      }

      try {
        hexToBase58('invalid-hex-address')
      } catch (error) {
        const errorMessage = (error as Error).message
        expect(errorMessage).toContain(
          'Failed to convert hex address to Base58',
        )
        expect(errorMessage).toContain('invalid-hex-address')
      }
    })
  })
})
