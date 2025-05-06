export async function execCMD(
  command: string,
  options: {} = {},
): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    // This is running locally so ignore github specific commands
    if (command.includes('>>') && !process.env.GITHUB_ENV) {
      const skipMessage = 'Command contains >>, skipping execution'
      console.log(skipMessage)
      resolve(skipMessage)
    } else {
      const { exec } = require('child_process')
      exec(command, options, (error: any, stdout: any, stderr: any) => {
        if (error) {
          console.error(`exec error: ${error}`)
          console.error(`stderr: ${stderr}`)
          reject(error)
          return
        }
        console.log(stdout)
        resolve(stdout)
      })
    }
  })
}
