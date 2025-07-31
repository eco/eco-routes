import { describe, it, expect } from '@jest/globals'
import { PublicKey } from '@solana/web3.js'
import {
  encodeReward,
  decodeReward,
  VmType,
  type EvmRewardType,
  type SvmRewardType,
} from '../assets/utils/intent'

describe('Intent Utils - Reward Encoding/Decoding', () => {
  describe('EVM Reward Encoding/Decoding', () => {
    it('should encode and decode EVM reward correctly', () => {
      const evmReward: EvmRewardType = {
        vm: VmType.EVM,
        creator: '0x1234567890123456789012345678901234567890' as `0x${string}`,
        prover: '0x9876543210987654321098765432109876543210' as `0x${string}`,
        deadline: 1735689600n,
        nativeAmount: 1000000000000000000n,
        tokens: [
          {
            token: '0xA0b86a33E6441e7c34A88A39bEAD93bB31d4fc6F' as `0x${string}`,
            amount: 500000000000000000n,
          },
          {
            token: '0xB1c86a33E6441e7c34A88A39bEAD93bB31d4fc6F' as `0x${string}`,
            amount: 250000000000000000n,
          },
        ],
      }

      const encoded = encodeReward(evmReward)
      const decoded = decodeReward(encoded)

      expect(decoded.vm).not.toBe(evmReward.vm)
      expect(decoded.creator).toBe(evmReward.creator)
      expect(decoded.prover).toBe(evmReward.prover)
      expect(decoded.deadline).toBe(evmReward.deadline)
      expect(decoded.nativeAmount).toBe(evmReward.nativeAmount)
      expect(decoded.tokens).toEqual(evmReward.tokens)
    })

    it('should handle EVM reward with no tokens', () => {
      const evmReward: EvmRewardType = {
        vm: VmType.EVM,
        creator: '0x1234567890123456789012345678901234567890' as `0x${string}`,
        prover: '0x9876543210987654321098765432109876543210' as `0x${string}`,
        deadline: 1735689600n,
        nativeAmount: 2000000000000000000n,
        tokens: [],
      }

      const encoded = encodeReward(evmReward)
      const decoded = decodeReward(encoded)

      expect(decoded).toEqual(evmReward)
    })
  })

  describe('SVM Reward Encoding/Decoding', () => {
    it('should encode and decode SVM reward correctly', () => {
      const svmReward: SvmRewardType = {
        vm: VmType.SVM,
        creator: new PublicKey('11111111111111111111111111111112'),
        prover: new PublicKey('11111111111111111111111111111113'),
        deadline: 1735689600n,
        nativeAmount: 1000000000n,
        tokens: [
          {
            token: new PublicKey('So11111111111111111111111111111111111111112'),
            amount: 500000000n,
          },
          {
            token: new PublicKey('EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v'),
            amount: 250000000n,
          },
        ],
      }

      const encoded = encodeReward(svmReward)
      const decoded = decodeReward(encoded)

      expect(decoded.vm).toBe(svmReward.vm)
      expect(decoded.creator).toEqual(svmReward.creator)
      expect(decoded.prover).toEqual(svmReward.prover)
      expect(decoded.deadline).toBe(svmReward.deadline)
      expect(decoded.nativeAmount).toBe(svmReward.nativeAmount)
      expect(decoded.tokens).toEqual(svmReward.tokens)
    })

    it('should handle SVM reward with no tokens', () => {
      const svmReward: SvmRewardType = {
        vm: VmType.SVM,
        creator: new PublicKey('11111111111111111111111111111112'),
        prover: new PublicKey('11111111111111111111111111111113'),
        deadline: 1735689600n,
        nativeAmount: 2000000000n,
        tokens: [],
      }

      const encoded = encodeReward(svmReward)
      const decoded = decodeReward(encoded)

      expect(decoded).toEqual(svmReward)
    })
  })

  describe('Edge Cases', () => {
    it('should handle zero amounts correctly', () => {
      const evmReward: EvmRewardType = {
        vm: VmType.EVM,
        creator: '0x1234567890123456789012345678901234567890' as `0x${string}`,
        prover: '0x9876543210987654321098765432109876543210' as `0x${string}`,
        deadline: 0n,
        nativeAmount: 0n,
        tokens: [
          {
            token: '0xA0b86a33E6441e7c34A88A39bEAD93bB31d4fc6F' as `0x${string}`,
            amount: 0n,
          },
        ],
      }

      const encoded = encodeReward(evmReward)
      const decoded = decodeReward(encoded)

      expect(decoded).toEqual(evmReward)
    })

    it('should handle large amounts correctly', () => {
      const largeAmount = BigInt('0xffffffffffffffffffffffffffffffff')
      const evmReward: EvmRewardType = {
        vm: VmType.EVM,
        creator: '0x1234567890123456789012345678901234567890' as `0x${string}`,
        prover: '0x9876543210987654321098765432109876543210' as `0x${string}`,
        deadline: largeAmount,
        nativeAmount: largeAmount,
        tokens: [
          {
            token: '0xA0b86a33E6441e7c34A88A39bEAD93bB31d4fc6F' as `0x${string}`,
            amount: largeAmount,
          },
        ],
      }

      const encoded = encodeReward(evmReward)
      const decoded = decodeReward(encoded)

      expect(decoded).toEqual(evmReward)
    })
  })
})