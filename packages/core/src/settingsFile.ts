import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

// Schema mirrors the official cosense-cli config file (cosense-cli src/lib/settings.ts,
// parseUsers/parseProjects): { users: [{url, token}], projects: [{url, serviceAccount}] }.
// url is matched by origin for users, by <origin>/<projectName> (case-insensitive path
// segment) for projects.

export interface UserSetting {
  origin: string
  token: string
}

export interface ProjectSetting {
  origin: string
  projectNameLc: string
  serviceAccount: string
}

export interface Settings {
  users: UserSetting[]
  projects: ProjectSetting[]
}

export class SettingsFileError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SettingsFileError'
  }
}

const defaultSettingsPath = (): string => join(homedir(), '.cosense', 'settings.json')

// CHATORA_SETTINGS_PATH is this package's override; COSENSE_SETTINGS_PATH is kept as a
// fallback alias since the architecture doc's test-strategy section names that variable.
export const resolveSettingsPath = (): string =>
  process.env.CHATORA_SETTINGS_PATH ?? process.env.COSENSE_SETTINGS_PATH ?? defaultSettingsPath()

const originOf = (url: string, path: string, context: string): string => {
  try {
    return new URL(url).origin
  } catch {
    throw new SettingsFileError(`${path}: ${context}.url is not a valid URL: ${url}`)
  }
}

const parseUsers = (raw: unknown, path: string): UserSetting[] => {
  if (raw === undefined) return []
  if (!Array.isArray(raw)) throw new SettingsFileError(`${path}: users must be an array`)
  return raw.map((entry, i) => {
    if (typeof entry !== 'object' || entry === null) {
      throw new SettingsFileError(`${path}: users[${i}] must be an object`)
    }
    const { url, token } = entry as { url?: unknown; token?: unknown }
    if (typeof url !== 'string')
      throw new SettingsFileError(`${path}: users[${i}].url must be a string`)
    if (typeof token !== 'string') {
      throw new SettingsFileError(`${path}: users[${i}].token must be a string`)
    }
    return { origin: originOf(url, path, `users[${i}]`), token }
  })
}

const parseProjects = (raw: unknown, path: string): ProjectSetting[] => {
  if (raw === undefined) return []
  if (!Array.isArray(raw)) throw new SettingsFileError(`${path}: projects must be an array`)
  return raw.map((entry, i) => {
    if (typeof entry !== 'object' || entry === null) {
      throw new SettingsFileError(`${path}: projects[${i}] must be an object`)
    }
    const { url, serviceAccount } = entry as { url?: unknown; serviceAccount?: unknown }
    if (typeof url !== 'string') {
      throw new SettingsFileError(`${path}: projects[${i}].url must be a string`)
    }
    if (typeof serviceAccount !== 'string') {
      throw new SettingsFileError(`${path}: projects[${i}].serviceAccount must be a string`)
    }
    const origin = originOf(url, path, `projects[${i}]`)
    const projectName = new URL(url).pathname.split('/').filter(Boolean)[0]
    if (!projectName) {
      throw new SettingsFileError(`${path}: projects[${i}].url must include a project path: ${url}`)
    }
    return { origin, projectNameLc: projectName.toLowerCase(), serviceAccount }
  })
}

/** Reads and validates the settings file. Returns null when it does not exist (not an error). */
export const readSettings = (path: string = resolveSettingsPath()): Settings | null => {
  let text: string
  try {
    text = readFileSync(path, 'utf8')
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return null
    throw err
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err)
    throw new SettingsFileError(`${path}: invalid JSON: ${detail}`)
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new SettingsFileError(`${path}: must be an object`)
  }
  const obj = parsed as { users?: unknown; projects?: unknown }
  return { users: parseUsers(obj.users, path), projects: parseProjects(obj.projects, path) }
}

export const findUserToken = (settings: Settings, origin: string): string | null => {
  const match = settings.users.find((u) => u.origin === origin)
  return match ? match.token : null
}

export const findProjectServiceAccount = (
  settings: Settings,
  origin: string,
  project: string,
): string | null => {
  const projectLc = project.toLowerCase()
  const match = settings.projects.find((p) => p.origin === origin && p.projectNameLc === projectLc)
  return match ? match.serviceAccount : null
}
