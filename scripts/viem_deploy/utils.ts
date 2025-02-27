/**
 * Compares two integer strings left to right by digit to get the larger one
 * @param num1 - The first integer string
 * @param num2 - The second integer string
 * @returns 1 if num1 is larger, -1 if num2 is larger, 0 if they are equal
 */
export function compareSemverIntegerStrings(
  num1: string,
  num2: string,
): number {
  const len1 = num1.length
  const len2 = num2.length

  // Pad the shorter string with trailing zeros
  if (len1 > len2) {
    num2 = num2.padEnd(len1, '0')
  } else if (len2 > len1) {
    num1 = num1.padEnd(len2, '0')
  }

  for (let i = 0; i < num1.length; i++) {
    const digit1 = parseInt(num1[i], 10)
    const digit2 = parseInt(num2[i], 10)

    if (digit1 > digit2) {
      return 1
    } else if (digit1 < digit2) {
      return -1
    }
  }

  return 0
}
