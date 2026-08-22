import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  findProjectServiceAccount,
  findUserToken,
  readSettings,
  resolveSettingsPath,
  SettingsFileError,
} from './settingsFile'

describe('settingsFile', () => {
  let dir: string

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'chatora-settings-'))
  })

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  test('readSettings returns null when the file does not exist', () => {
    expect(readSettings(join(dir, 'missing.json'))).toBeNull()
  })

  test('readSettings parses the official cosense-cli schema', async () => {
    const path = join(dir, 'settings.json')
    await writeFile(
      path,
      JSON.stringify({
        users: [{ url: 'https://scrapbox.io', token: 'pat-1' }],
        projects: [{ url: 'https://scrapbox.io/MyProject', serviceAccount: 'cs_abc' }],
      }),
    )
    const settings = readSettings(path)
    expect(settings).not.toBeNull()
    expect(settings?.users).toEqual([{ origin: 'https://scrapbox.io', token: 'pat-1' }])
    expect(settings?.projects).toEqual([
      { origin: 'https://scrapbox.io', projectNameLc: 'myproject', serviceAccount: 'cs_abc' },
    ])
  })

  test('readSettings throws SettingsFileError on invalid JSON', async () => {
    const path = join(dir, 'settings.json')
    await writeFile(path, '{not json')
    expect(() => readSettings(path)).toThrow(SettingsFileError)
  })

  test('readSettings throws SettingsFileError when users is not an array', async () => {
    const path = join(dir, 'settings.json')
    await writeFile(path, JSON.stringify({ users: 'nope' }))
    expect(() => readSettings(path)).toThrow(SettingsFileError)
  })

  test('findUserToken matches by origin', () => {
    const settings = {
      users: [{ origin: 'https://scrapbox.io', token: 'pat-1' }],
      projects: [],
    }
    expect(findUserToken(settings, 'https://scrapbox.io')).toBe('pat-1')
    expect(findUserToken(settings, 'https://other.example')).toBeNull()
  })

  test('findProjectServiceAccount matches by origin + case-insensitive project name', () => {
    const settings = {
      users: [],
      projects: [
        { origin: 'https://scrapbox.io', projectNameLc: 'myproject', serviceAccount: 'cs_abc' },
      ],
    }
    expect(findProjectServiceAccount(settings, 'https://scrapbox.io', 'MyProject')).toBe('cs_abc')
    expect(findProjectServiceAccount(settings, 'https://scrapbox.io', 'other')).toBeNull()
  })

  test('resolveSettingsPath honors CHATORA_SETTINGS_PATH then COSENSE_SETTINGS_PATH then default', () => {
    const prevChatora = process.env.CHATORA_SETTINGS_PATH
    const prevCosense = process.env.COSENSE_SETTINGS_PATH
    try {
      process.env.CHATORA_SETTINGS_PATH = '/tmp/chatora-path.json'
      process.env.COSENSE_SETTINGS_PATH = '/tmp/cosense-path.json'
      expect(resolveSettingsPath()).toBe('/tmp/chatora-path.json')

      delete process.env.CHATORA_SETTINGS_PATH
      expect(resolveSettingsPath()).toBe('/tmp/cosense-path.json')

      delete process.env.COSENSE_SETTINGS_PATH
      expect(resolveSettingsPath().endsWith('.cosense/settings.json')).toBe(true)
    } finally {
      if (prevChatora === undefined) delete process.env.CHATORA_SETTINGS_PATH
      else process.env.CHATORA_SETTINGS_PATH = prevChatora
      if (prevCosense === undefined) delete process.env.COSENSE_SETTINGS_PATH
      else process.env.COSENSE_SETTINGS_PATH = prevCosense
    }
  })
})
