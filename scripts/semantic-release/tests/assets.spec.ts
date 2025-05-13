import fs from 'fs'
import path from 'path'

describe('semantic-release assets directory structure', () => {
  it('should maintain the expected directory structure', () => {
    // Get the base directory for the semantic-release scripts
    const baseDir = path.resolve(__dirname, '..')
    const assetsDir = path.join(baseDir, 'assets')
    const utilsDir = path.join(assetsDir, 'utils')

    // Check the assets directory exists
    expect(fs.existsSync(assetsDir)).toBe(true)
    expect(fs.statSync(assetsDir).isDirectory()).toBe(true)

    // Check the utils directory exists
    expect(fs.existsSync(utilsDir)).toBe(true)
    expect(fs.statSync(utilsDir).isDirectory()).toBe(true)

    // Check expected utility files exist
    const expectedUtilFiles = ['helper.ts', 'index.ts', 'intent.ts', 'utils.ts']
    const actualUtilFiles = fs
      .readdirSync(utilsDir)
      .filter((file) => file.endsWith('.ts'))
      .sort()

    expect(actualUtilFiles).toEqual(expectedUtilFiles)

    // Check that index.ts exports all utils modules
    const indexContent = fs.readFileSync(
      path.join(utilsDir, 'index.ts'),
      'utf8',
    )

    // Verify that each utility file (except index.ts itself) is exported
    expectedUtilFiles
      .filter((file) => file !== 'index.ts')
      .forEach((file) => {
        const moduleName = file.replace('.ts', '')
        expect(indexContent).toContain(`export * from './${moduleName}'`)
      })

    // Verify no unexpected directories exist in assets
    const topLevelDirs = fs
      .readdirSync(assetsDir)
      .filter((item) => fs.statSync(path.join(assetsDir, item)).isDirectory())

    expect(topLevelDirs).toEqual(['utils'])
  })

  it('should contain the required utility files with content', () => {
    const baseDir = path.resolve(__dirname, '..')
    const utilsDir = path.join(baseDir, 'assets', 'utils')

    // Check each utility file has content
    const utilFiles = ['helper.ts', 'intent.ts', 'utils.ts']

    utilFiles.forEach((file) => {
      const filePath = path.join(utilsDir, file)
      expect(fs.existsSync(filePath)).toBe(true)

      const content = fs.readFileSync(filePath, 'utf8')
      expect(content.length).toBeGreaterThan(0)
    })
  })
})
