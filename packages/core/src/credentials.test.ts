import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { resolveCredential } from './credentials'
import type { ExecFileFn } from './keychain'

const ORIGIN = 'https://scrapbox.io'

const withEnvPat = async <T>(value: string | undefined, fn: () => Promise<T>): Promise<T> => {
  const prev = process.env.COSENSE_PAT
  if (value === undefined) delete process.env.COSENSE_PAT
  else process.env.COSENSE_PAT = value
  try {
    return await fn()
  } finally {
    if (prev === undefined) delete process.env.COSENSE_PAT
    else process.env.COSENSE_PAT = prev
  }
}

const notFoundExec: ExecFileFn = async () => {
  throw new Error('security: item not found')
}

describe('resolveCredential precedence: env > keychain > settingsJson', () => {
  let dir: string
  let settingsPath: string

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'chatora-creds-'))
    settingsPath = join(dir, 'settings.json')
  })

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  test('env COSENSE_PAT wins even when keychain and settings.json also have entries', async () => {
    await writeFile(
      settingsPath,
      JSON.stringify({ users: [{ url: ORIGIN, token: 'settings-pat' }], projects: [] }),
    )
    const exec: ExecFileFn = async () => ({ stdout: 'keychain-pat', stderr: '' })

    const credential = await withEnvPat('env-pat', () =>
      resolveCredential(ORIGIN, undefined, { execFile: exec, settingsPath }),
    )
    expect(credential).toEqual({ type: 'pat', value: 'env-pat', source: 'env' })
  })

  test('keychain wins over settings.json when env is unset', async () => {
    await writeFile(
      settingsPath,
      JSON.stringify({ users: [{ url: ORIGIN, token: 'settings-pat' }], projects: [] }),
    )
    const exec: ExecFileFn = async () => ({ stdout: 'keychain-pat\n', stderr: '' })

    const credential = await withEnvPat(undefined, () =>
      resolveCredential(ORIGIN, undefined, { execFile: exec, settingsPath }),
    )
    expect(credential).toEqual({ type: 'pat', value: 'keychain-pat', source: 'keychain' })
  })

  test('falls back to settings.json users[] (PAT) when keychain has no entry', async () => {
    await writeFile(
      settingsPath,
      JSON.stringify({ users: [{ url: ORIGIN, token: 'settings-pat' }], projects: [] }),
    )
    const credential = await withEnvPat(undefined, () =>
      resolveCredential(ORIGIN, undefined, { execFile: notFoundExec, settingsPath }),
    )
    expect(credential).toEqual({ type: 'pat', value: 'settings-pat', source: 'settingsJson' })
  })

  test('settings.json projects[] (serviceAccount) takes priority over users[] when project is given', async () => {
    await writeFile(
      settingsPath,
      JSON.stringify({
        users: [{ url: ORIGIN, token: 'settings-pat' }],
        projects: [{ url: `${ORIGIN}/myproject`, serviceAccount: 'cs_abc' }],
      }),
    )
    const credential = await withEnvPat(undefined, () =>
      resolveCredential(ORIGIN, 'myproject', { execFile: notFoundExec, settingsPath }),
    )
    expect(credential).toEqual({ type: 'serviceAccount', value: 'cs_abc', source: 'settingsJson' })
  })

  test('falls back to users[] PAT when project is given but has no serviceAccount entry', async () => {
    await writeFile(
      settingsPath,
      JSON.stringify({ users: [{ url: ORIGIN, token: 'settings-pat' }], projects: [] }),
    )
    const credential = await withEnvPat(undefined, () =>
      resolveCredential(ORIGIN, 'myproject', { execFile: notFoundExec, settingsPath }),
    )
    expect(credential).toEqual({ type: 'pat', value: 'settings-pat', source: 'settingsJson' })
  })

  test('returns null when no source has a matching entry', async () => {
    await writeFile(settingsPath, JSON.stringify({ users: [], projects: [] }))
    const credential = await withEnvPat(undefined, () =>
      resolveCredential(ORIGIN, undefined, { execFile: notFoundExec, settingsPath }),
    )
    expect(credential).toBeNull()
  })

  test('returns null when settings.json does not exist and nothing else matches', async () => {
    const credential = await withEnvPat(undefined, () =>
      resolveCredential(ORIGIN, undefined, {
        execFile: notFoundExec,
        settingsPath: join(dir, 'missing.json'),
      }),
    )
    expect(credential).toBeNull()
  })
})
