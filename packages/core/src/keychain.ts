import { execFile as execFileCb } from 'node:child_process'
import { promisify } from 'node:util'

/** Injectable exec runner so tests never shell out to the real `security` binary. */
export type ExecFileFn = (
  file: string,
  args: string[],
) => Promise<{ stdout: string; stderr: string }>

export const execFileAsync: ExecFileFn = promisify(execFileCb)

/** Thrown by write operations on non-darwin platforms. Read operations soft-fail to null instead. */
export class KeychainUnavailableError extends Error {
  constructor(message = 'macOS Keychain is only available on darwin') {
    super(message)
    this.name = 'KeychainUnavailableError'
  }
}

const SERVICE = 'chatora'

/** `security find-generic-password -s chatora -a <origin> -w`. Soft-fails to null (missing item, non-darwin, etc). */
export const findGenericPassword = async (
  origin: string,
  execFileFn: ExecFileFn = execFileAsync,
): Promise<string | null> => {
  if (process.platform !== 'darwin') return null
  try {
    const { stdout } = await execFileFn('security', [
      'find-generic-password',
      '-s',
      SERVICE,
      '-a',
      origin,
      '-w',
    ])
    const value = stdout.trim()
    return value === '' ? null : value
  } catch {
    return null
  }
}

/** `security add-generic-password -U -s chatora -a <origin> -w <pat>`. Args array only, never a shell string. */
export const addGenericPassword = async (
  origin: string,
  pat: string,
  execFileFn: ExecFileFn = execFileAsync,
): Promise<void> => {
  if (process.platform !== 'darwin') throw new KeychainUnavailableError()
  await execFileFn('security', [
    'add-generic-password',
    '-U',
    '-s',
    SERVICE,
    '-a',
    origin,
    '-w',
    pat,
  ])
}

/** `security delete-generic-password -s chatora -a <origin>`. */
export const deleteGenericPassword = async (
  origin: string,
  execFileFn: ExecFileFn = execFileAsync,
): Promise<void> => {
  if (process.platform !== 'darwin') throw new KeychainUnavailableError()
  await execFileFn('security', ['delete-generic-password', '-s', SERVICE, '-a', origin])
}
