import { ethers } from 'ethers'

/**
 * TypeCasts utility functions for converting between address and bytes32
 * Mirrors the Solidity TypeCasts library functionality
 */
export class TypeCasts {
  /**
   * Converts an address to bytes32 (alignment preserving)
   * @param address The address to convert
   * @returns The bytes32 representation
   */
  static addressToBytes32(address: string): string {
    // Convert address to uint160, then to uint256, then to bytes32
    return ethers.zeroPadValue(address, 32)
  }

  /**
   * Converts a bytes32 to address (alignment preserving)
   * @param bytes32 The bytes32 to convert
   * @returns The address representation
   */
  static bytes32ToAddress(bytes32: string): string {
    // Extract the lower 20 bytes (40 hex chars) which represent the address
    return ethers.getAddress('0x' + bytes32.slice(-40))
  }

  /**
   * Converts an array of addresses to bytes32 array
   * @param addresses Array of addresses
   * @returns Array of bytes32 representations
   */
  static addressesToBytes32Array(addresses: string[]): string[] {
    return addresses.map((addr) => this.addressToBytes32(addr))
  }

  /**
   * Converts an array of bytes32 to address array
   * @param bytes32Array Array of bytes32
   * @returns Array of addresses
   */
  static bytes32ArrayToAddresses(bytes32Array: string[]): string[] {
    return bytes32Array.map((b32) => this.bytes32ToAddress(b32))
  }
}

// Export convenience functions
export const addressToBytes32 = TypeCasts.addressToBytes32.bind(TypeCasts)
export const bytes32ToAddress = TypeCasts.bytes32ToAddress.bind(TypeCasts)
export const addressesToBytes32Array =
  TypeCasts.addressesToBytes32Array.bind(TypeCasts)
export const bytes32ArrayToAddresses =
  TypeCasts.bytes32ArrayToAddresses.bind(TypeCasts)
