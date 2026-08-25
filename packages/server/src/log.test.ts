import { afterEach, describe, expect, test } from 'bun:test'
import { mkdtempSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Effect } from 'effect'
import { activeLogPath, log } from './log'

const withEnv = async (env: Record<string, string | undefined>, run: () => Promise<void>) => {
  const saved = {
    CHATORA_LOG: process.env.CHATORA_LOG,
    CHATORA_STATE_DIR: process.env.CHATORA_STATE_DIR,
  }
  Object.assign(process.env, env)
  try {
    await run()
  } finally {
    Object.assign(process.env, saved)
  }
}

afterEach(() => {
  process.env.CHATORA_LOG = undefined
})

describe('log', () => {
  test('writes nothing at all when CHATORA_LOG is unset', async () => {
    await withEnv({ CHATORA_LOG: undefined }, async () => {
      expect(activeLogPath()).toBeUndefined()
      await Effect.runPromise(log('warn', 'ignored'))
    })
  })

  test('"0" and "false" turn it off as plainly as an unset variable', async () => {
    for (const off of ['0', 'false', '']) {
      await withEnv({ CHATORA_LOG: off }, async () => expect(activeLogPath()).toBeUndefined())
    }
  })

  test('a path value is written to verbatim, one greppable record per call', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'chatora-log-'))
    const path = join(dir, 'diag.log')
    await withEnv({ CHATORA_LOG: path }, async () => {
      await Effect.runPromise(
        log('warn', 'asset fetch failed', { url: 'https://x/y.png', status: 404 }),
      )
      await Effect.runPromise(log('info', 'second'))
    })
    const lines = readFileSync(path, 'utf8').trimEnd().split('\n')
    expect(lines).toHaveLength(2)
    expect(lines[0]).toContain('warn asset fetch failed url="https://x/y.png" status="404"')
    expect(lines[1]).toContain('info second')
  })

  test('"1" resolves to the state directory', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'chatora-state-'))
    await withEnv({ CHATORA_LOG: '1', CHATORA_STATE_DIR: dir }, async () => {
      expect(activeLogPath()).toBe(join(dir, 'chatora.log'))
    })
  })

  test('undefined fields are dropped rather than logged as "undefined"', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'chatora-log-'))
    const path = join(dir, 'diag.log')
    await withEnv({ CHATORA_LOG: path }, async () => {
      await Effect.runPromise(log('warn', 'partial', { url: 'u', detail: undefined }))
    })
    expect(readFileSync(path, 'utf8')).toContain('partial url="u"\n')
  })
})
