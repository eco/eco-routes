/** @type {import('ts-jest').JestConfigWithTsJest} **/
module.exports = {
  testEnvironment: 'node',
  testPathIgnorePatterns: ['/node_modules/'],
  testMatch: [
    '**/scripts/semantic-release/tests/**/*.spec.ts',
    '**/src/__tests__/**/*.test.ts',
  ],
  transform: {
    '^.+\\.tsx?$': ['ts-jest', {}],
  },
  passWithNoTests: true,
}
