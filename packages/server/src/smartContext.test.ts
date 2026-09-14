import { afterAll, beforeAll, describe, expect, test } from 'bun:test'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { Credential } from '@chatora/core'
import { CredentialStore, HttpClient } from '@chatora/core'
import { Effect, Layer, Option } from 'effect'
import { exportForAi, fileNameFor } from './smartContext'
import { makeSessionStateLayer } from './state'

const ORIGIN = 'https://scrapbox.io'
const PAT: Credential = { type: 'pat', value: 'secret-pat', source: 'keychain' }

let dir: string
beforeAll(async () => {
  dir = await mkdtemp(join(tmpdir(), 'chatora-export-'))
  process.env.CHATORA_EXPORT_DIR = dir
})
afterAll(async () => {
  delete process.env.CHATORA_EXPORT_DIR
  await rm(dir, { recursive: true, force: true })
})

/** Runs one export against a fake Cosense, with or without a credential behind it. */
const run = (
  params: { project: string; title: string; hop: 1 | 2; search?: string },
  respond: () => Response,
  credential: Option.Option<Credential> = Option.some(PAT),
) => {
  const calls: string[] = []
  const httpLayer = Layer.succeed(
    HttpClient,
    HttpClient.of({
      fetch: (url) => {
        calls.push(url)
        return Effect.sync(respond)
      },
    }),
  )
  const credentialLayer = Layer.succeed(
    CredentialStore,
    CredentialStore.of({
      resolve: () => Effect.succeed(credential),
      store: () => Effect.void,
      remove: () => Effect.void,
    }),
  )
  const result = Effect.runPromise(
    exportForAi(params).pipe(
      Effect.provide(httpLayer),
      Effect.provide(makeSessionStateLayer(ORIGIN).pipe(Layer.provide(credentialLayer))),
    ),
  )
  return { result, calls }
}

describe('fileNameFor', () => {
  test('names the file after the page and the hop', () => {
    expect(fileNameFor('Side Kanban', 1)).toBe('Side Kanban-1hop.txt')
    expect(fileNameFor('Side Kanban', 2)).toBe('Side Kanban-2hop.txt')
  })

  test('a title that would read as a path names a file all the same', () => {
    expect(fileNameFor('a/b: c?', 1)).toBe('a_b_ c_-1hop.txt')
  })

  test('a long title is cut, and an empty one still has a name', () => {
    expect(fileNameFor('あ'.repeat(200), 1)).toBe(`${'あ'.repeat(80)}-1hop.txt`)
    expect(fileNameFor('   ', 2)).toBe('page-2hop.txt')
  })
})

describe('exportForAi', () => {
  test('writes what Cosense answers, and says where', async () => {
    const { result, calls } = run(
      { project: 'my-project', title: 'ページ', hop: 1 },
      () => new Response('export text', { headers: { 'content-type': 'text/plain' } }),
    )
    const answer = await result
    expect(answer).toEqual({
      ok: true,
      path: join(dir, 'my-project', 'ページ-1hop.txt'),
      bytes: 11,
    })
    expect(await readFile(join(dir, 'my-project', 'ページ-1hop.txt'), 'utf8')).toBe('export text')
    expect(calls[0]).toBe(
      'https://scrapbox.io/api/smart-context/export-1hop-links/my-project.txt?title=%E3%83%9A%E3%83%BC%E3%82%B8',
    )
  })

  test('two hops ask the other endpoint and keep the search filter', async () => {
    const { result, calls } = run(
      { project: 'my-project', title: 'ページ', hop: 2, search: 'sakura' },
      () => new Response('text'),
    )
    await result
    expect(calls[0]).toContain('/export-2hop-links/my-project.txt?')
    expect(calls[0]).toContain('search=sakura')
  })

  test('a refused request comes back as the unauthorized envelope, and writes nothing', async () => {
    const { result } = run(
      { project: 'my-project', title: '断られる', hop: 1 },
      () => new Response('{"name":"NotLoggedInError"}', { status: 401 }),
    )
    expect(await result).toEqual({
      ok: false,
      code: 'unauthorized',
      message: 'authentication failed',
    })
    expect(
      await readFile(join(dir, 'my-project', '断られる-1hop.txt'), 'utf8').catch(() => null),
    ).toBeNull()
  })

  test('no credential, no request', async () => {
    const { result, calls } = run(
      { project: 'my-project', title: 'ページ', hop: 1 },
      () => new Response('text'),
      Option.none(),
    )
    expect(await result).toEqual({ ok: false, code: 'unauthorized', message: 'not logged in' })
    expect(calls).toEqual([])
  })
})
