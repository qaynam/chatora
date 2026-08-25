import { appendFile, mkdir } from 'node:fs/promises'
import { dirname } from 'node:path'
import { stateFilePath } from '@chatora/core'
import { Effect } from 'effect'

// Opt-in diagnostic log for the failures chatora deliberately swallows — a picture that
// silently does not appear, an asset that 404s — where the user otherwise has nothing to
// go on. `CHATORA_LOG=1` writes to the default path below, any other value is the path
// itself, and an unset variable disables the whole module.
const DEFAULT_LOG_NAME = 'chatora.log'

const logPath = (): string | undefined => {
  const setting = process.env.CHATORA_LOG
  if (setting === undefined || setting === '' || setting === '0' || setting === 'false') {
    return undefined
  }
  return setting === '1' || setting === 'true' ? stateFilePath(DEFAULT_LOG_NAME) : setting
}

/** Where the log is being written, or undefined when logging is off. For `chatora/logPath`. */
export const activeLogPath = (): string | undefined => logPath()

const write = async (line: string): Promise<void> => {
  const path = logPath()
  if (path === undefined) return
  await mkdir(dirname(path), { recursive: true })
  await appendFile(path, line)
}

/**
 * Append one record, or do nothing when logging is off. `fields` are rendered as
 * `key=value` after the message, so the file stays greppable (`rg 'status=404'`). A write
 * error is dropped: a broken log must not turn a working feature into a failed request.
 */
export const log = (
  level: 'warn' | 'info',
  message: string,
  fields: Readonly<Record<string, string | number | undefined>> = {},
): Effect.Effect<void> => {
  if (logPath() === undefined) return Effect.void
  const parts = Object.entries(fields)
    .filter(([, value]) => value !== undefined)
    .map(([key, value]) => `${key}=${JSON.stringify(String(value))}`)
  const line = `${new Date().toISOString()} ${level} ${message}${parts.length > 0 ? ` ${parts.join(' ')}` : ''}\n`
  return Effect.promise(() => write(line).catch(() => {}))
}
