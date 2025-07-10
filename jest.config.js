/** @type {import('ts-jest').JestConfigWithTsJest} **/
module.exports = {
  testEnvironment: 'node',
  testPathIgnorePatterns: ['/node_modules/'],
  testMatch: ['**/scripts/semantic-release/tests/**/*.spec.ts'],
  transform: {
    '^.+\\.tsx?$': ['ts-jest', {}],
  },
  passWithNoTests: true,
}
