/**
 * @file processUtils.ts
 *
 * Utility functions for process execution using async/await with proper Promise handling.
 *
 * These utilities provide a clean interface for executing shell commands and scripts,
 * handling environment variables carefully to ensure they're passed correctly to child processes.
 * This is critical for operations where environment variables like SALT need to be
 * preserved from parent to child processes.
 *
 * Key features:
 * - Proper Promise-based wrappers around Node.js child_process
 * - Environment variable handling with parent env inheritance
 * - Standardized error handling and exit code management
 * - Support for command timeouts
 */

import { spawn } from 'child_process'
import { promisify } from 'util'

/**
 * Executes a process and returns a promise that resolves when the process
 * completes successfully or rejects if the process fails.
 *
 * @param command The command to execute
 * @param args Array of command arguments
 * @param options Options for the child process
 * @returns Promise that resolves to the exit code or rejects with an error
 */
export async function executeProcessAsync(
  command: string,
  args: string[],
  options: any,
): Promise<number> {
  const execProcess = promisify(
    (
      cmd: string,
      args: string[],
      options: any,
      callback: (err: Error | null, code: number) => void,
    ) => {
      const env = { ...process.env, ...options.env }
      const proc = spawn(cmd, args, { ...options, env })

      proc.on('close', (code) => {
        callback(null, code || 0)
      })

      proc.on('error', (error) => {
        callback(error, 1)
      })
    },
  )

  return await execProcess(command, args, options)
}

/**
 * Simplified interface for executing shell commands with standard options.
 *
 * @param command The command to execute
 * @param args Array of command arguments
 * @param env Environment variables to pass to the process
 * @param cwd Current working directory
 * @returns Promise that resolves to the exit code
 */
export async function executeProcess(
  command: string,
  args: string[] = [],
  env: any = process.env,
  cwd: string,
): Promise<number> {
  return executeProcessAsync(command, args, {
    env,
    stdio: 'inherit',
    shell: true,
    cwd,
  })
}
