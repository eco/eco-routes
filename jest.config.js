/** @type {import('ts-jest').JestConfigWithTsJest} **/
module.exports = {
  testEnvironment: 'node',
  testPathIgnorePatterns: ['/node_modules/'],
  testMatch: [
    '**/scripts/release/tests/**/*.spec.ts',
    '**/scripts/tron/tests/**/*.spec.ts',
  ],
  transform: {
    '^.+\\.tsx?$': ['ts-jest', {}],
  },
  passWithNoTests: true,
}
