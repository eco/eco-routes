module.exports = {
  env: {
    browser: false,
    es2021: true,
    mocha: true,
    node: true,
  },
  extends: [
    'standard',
    'plugin:prettier/recommended',
    'plugin:node/recommended',
  ],
  plugins: ['@typescript-eslint', 'mocha', 'chai-friendly'],
  parser: '@typescript-eslint/parser',
  parserOptions: {
    ecmaVersion: 12,
  },

  rules: {
    'no-useless-constructor': 0,
    'no-unused-expressions': 0,
    'no-plusplus': 0,
    'prefer-destructuring': 0,
    'mocha/no-exclusive-tests': 'error',
    'chai-friendly/no-unused-expressions': 2,
    'no-multiple-empty-lines': [
      'error',
      {
        max: 1,
        maxEOF: 0,
        maxBOF: 0,
      },
    ],
    'node/no-unsupported-features/es-syntax': [
      'error',
      { ignores: ['modules'] },
    ],
    'node/no-missing-import': [
      'error',
      {
        allowModules: [],
        tryExtensions: ['.js', '.json', '.node', '.ts', '.d.ts'],
      },
    ],
    'node/no-missing-require': [
      'error',
      {
        allowModules: [],
        tryExtensions: ['.js', '.json', '.node', '.ts', '.d.ts'],
      },
    ],
    camelcase: 0,
  },
  globals: {
    ethers: 'readonly',
  },
}
