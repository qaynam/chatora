import type { ExecFileFn } from './keychain'
import {
  addGenericPassword,
  deleteGenericPassword,
  execFileAsync,
  findGenericPassword,
} from './keychain'
import {
  findProjectServiceAccount,
  findUserToken,
  readSettings,
  resolveSettingsPath,
} from './settingsFile'

export type CredentialSource = 'env' | 'keychain' | 'settingsJson'
export type CredentialType = 'pat' | 'serviceAccount'

export interface Credential {
  type: CredentialType
  value: string
  source: CredentialSource
}

/** Extra seam for tests only — @chatora/server always calls resolveCredential(origin, project). */
export interface ResolveCredentialDeps {
  execFile?: ExecFileFn
  settingsPath?: string
}

const readEnvCredential = (): Credential | null => {
  const raw = process.env.COSENSE_PAT
  if (typeof raw !== 'string') return null
  const value = raw.trim()
  if (value === '') return null
  return { type: 'pat', value, source: 'env' }
}

/**
 * Resolution order (architecture doc / cosense-cli src/lib/settings.ts resolveCredential):
 *   1. env COSENSE_PAT
 *   2. macOS Keychain (service "chatora", account = origin)
 *   3. ~/.cosense/settings.json — projects[] (by origin+project, -> serviceAccount) checked
 *      before users[] (by origin, -> PAT), matching cosense-cli's own precedence when a
 *      project name is available.
 * `project` is optional: without it, only settings.json's users[] is consulted (like
 * cosense-cli's resolveUserCredential, used for origin-only calls such as listProjects/me).
 */
export const resolveCredential = async (
  origin: string,
  project?: string,
  deps: ResolveCredentialDeps = {},
): Promise<Credential | null> => {
  const env = readEnvCredential()
  if (env) return env

  const keychainValue = await findGenericPassword(origin, deps.execFile ?? execFileAsync)
  if (keychainValue) return { type: 'pat', value: keychainValue, source: 'keychain' }

  const settings = readSettings(deps.settingsPath ?? resolveSettingsPath())
  if (settings) {
    if (project) {
      const serviceAccount = findProjectServiceAccount(settings, origin, project)
      if (serviceAccount)
        return { type: 'serviceAccount', value: serviceAccount, source: 'settingsJson' }
    }
    const token = findUserToken(settings, origin)
    if (token) return { type: 'pat', value: token, source: 'settingsJson' }
  }

  return null
}

/** Login storage is Keychain-only — never written to settings.json. */
export const storeCredential = async (
  origin: string,
  pat: string,
  execFileFn: ExecFileFn = execFileAsync,
): Promise<void> => {
  await addGenericPassword(origin, pat, execFileFn)
}

export const deleteCredential = async (
  origin: string,
  execFileFn: ExecFileFn = execFileAsync,
): Promise<void> => {
  await deleteGenericPassword(origin, execFileFn)
}
