import { homedir } from 'node:os'
import { join } from 'node:path'

/**
 * Path of one of chatora's own state files. `CHATORA_STATE_DIR` overrides the whole directory
 * (the test override point); otherwise `${XDG_STATE_HOME:-$HOME/.local/state}/chatora`.
 * Resolved per call rather than once per process, so tests can repoint it between cases.
 */
export const stateFilePath = (name: string): string => {
  const override = process.env.CHATORA_STATE_DIR
  if (override !== undefined && override !== '') return join(override, name)
  const xdgStateHome = process.env.XDG_STATE_HOME
  const stateHome =
    xdgStateHome !== undefined && xdgStateHome !== ''
      ? xdgStateHome
      : join(homedir(), '.local', 'state')
  return join(stateHome, 'chatora', name)
}
