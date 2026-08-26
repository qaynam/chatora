import { describe, expect, test } from 'bun:test'
import type { Credential, Me } from '@chatora/core'
import { CredentialStore, HttpClient } from '@chatora/core'
import { Effect, Layer, Option, TestClock, TestContext } from 'effect'
import { makeSessionStateLayer, SessionState } from './state'

const ORIGIN = 'https://scrapbox.io'
const PAT: Credential = { type: 'pat', value: 'secret-pat', source: 'keychain' }
const ME: Me = { id: 'u1', name: 'qaynam', displayName: 'Qaynam', pageFilters: [] }

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

const testHttpClient = (
  handler: (url: string) => Response,
): { layer: Layer.Layer<HttpClient>; calls: string[] } => {
  const calls: string[] = []
  const layer = Layer.succeed(
    HttpClient,
    HttpClient.of({
      fetch: (input) => {
        calls.push(input)
        return Effect.sync(() => handler(input))
      },
    }),
  )
  return { layer, calls }
}

const testCredentialStore = (
  initial: Option.Option<Credential>,
): { layer: Layer.Layer<CredentialStore>; calls: { resolveCalls: number } } => {
  // A plain mutable counter, not a destructured primitive: the assertions below read it
  // after the program has run, so the caller must hold onto this same object.
  const calls = { resolveCalls: 0 }
  const layer = Layer.succeed(
    CredentialStore,
    CredentialStore.of({
      resolve: () => {
        calls.resolveCalls++
        return Effect.succeed(initial)
      },
      store: () => Effect.void,
      remove: () => Effect.void,
    }),
  )
  return { layer, calls }
}

/** Runs a SessionState-dependent program against fake HttpClient/CredentialStore layers, with TestClock so TTL caches are exercised deterministically. */
const run = <A, E>(
  program: Effect.Effect<A, E, SessionState | HttpClient>,
  httpLayer: Layer.Layer<HttpClient>,
  credentialLayer: Layer.Layer<CredentialStore>,
): Promise<A> =>
  Effect.runPromise(
    program.pipe(
      Effect.provide(httpLayer),
      Effect.provide(makeSessionStateLayer(ORIGIN).pipe(Layer.provide(credentialLayer))),
      Effect.provide(TestContext.TestContext),
    ),
  )

describe('SessionState.getCredential', () => {
  test('resolves once and caches the result for the rest of the session', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({}))
    const { layer: credLayer, calls } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      const first = yield* session.getCredential()
      const second = yield* session.getCredential()
      return [first, second] as const
    })
    const [first, second] = await run(program, httpLayer, credLayer)
    expect(first).toEqual(Option.some(PAT))
    expect(second).toEqual(Option.some(PAT))
    expect(calls.resolveCalls).toBe(1)
  })

  test('caches "no credential" too, without retrying every call', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({}))
    const { layer: credLayer, calls } = testCredentialStore(Option.none())
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      yield* session.getCredential()
      return yield* session.getCredential()
    })
    const result = await run(program, httpLayer, credLayer)
    expect(result).toEqual(Option.none())
    expect(calls.resolveCalls).toBe(1)
  })

  test('invalidateCredentials forces the next getCredential to re-resolve', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({}))
    const { layer: credLayer, calls } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      yield* session.getCredential()
      yield* session.invalidateCredentials()
      yield* session.getCredential()
    })
    await run(program, httpLayer, credLayer)
    expect(calls.resolveCalls).toBe(2)
  })
})

describe('SessionState.ensureVerified', () => {
  test('verifies once and caches a successful result', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() =>
      json({ id: ME.id, name: ME.name, displayName: ME.displayName }),
    )
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      const first = yield* session.ensureVerified()
      const second = yield* session.ensureVerified()
      return [first, second] as const
    })
    const [first, second] = await run(program, httpLayer, credLayer)
    expect(first).toEqual(Option.some(ME))
    expect(second).toEqual(Option.some(ME))
    expect(calls).toHaveLength(1)
  })

  test('caches a failed verification too — no retry within the session', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() => new Response('nope', { status: 401 }))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      const first = yield* session.ensureVerified()
      const second = yield* session.ensureVerified()
      return [first, second] as const
    })
    const [first, second] = await run(program, httpLayer, credLayer)
    expect(first).toEqual(Option.none())
    expect(second).toEqual(Option.none())
    expect(calls).toHaveLength(1)
  })

  test('without a credential, never calls the API and stays retriable', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() => json({}))
    const { layer: credLayer } = testCredentialStore(Option.none())
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      return yield* session.ensureVerified()
    })
    const result = await run(program, httpLayer, credLayer)
    expect(result).toEqual(Option.none())
    expect(calls).toHaveLength(0)
  })

  test('setVerifiedUser (login path) seeds the cache without calling the API', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() => json({}))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      yield* session.setVerifiedUser(ME)
      return yield* session.ensureVerified()
    })
    const result = await run(program, httpLayer, credLayer)
    expect(result).toEqual(Option.some(ME))
    expect(calls).toHaveLength(0)
  })
})

// Each test uses its own project name: the index is cached on disk as well as in memory,
// so two tests sharing one would share the file the first of them wrote.
describe('SessionState.getTitles (cached in memory and on disk)', () => {
  test('serves repeated calls for the same project from cache', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() =>
      json([{ id: 't1', title: 'A', titleLc: 'a', updated: 1, image: null }]),
    )
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      yield* session.getTitles('cached')
      return yield* session.getTitles('cached')
    })
    const result = await run(program, httpLayer, credLayer)
    expect(result).toHaveLength(1)
    expect(calls).toHaveLength(1)
  })

  test('refetches once the TTL has elapsed', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() => json([]))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      yield* session.getTitles('expiring')
      yield* TestClock.adjust('301 seconds')
      yield* session.getTitles('expiring')
    })
    await run(program, httpLayer, credLayer)
    expect(calls).toHaveLength(2)
  })

  // The list is worth hundreds of kilobytes per project, so a fresh session reads what the
  // last one stored instead of downloading it again before the first link can be judged.
  test('a second session reads the stored list instead of refetching', async () => {
    const entry = { id: 't1', title: 'A', titleLc: 'a', updated: 1, image: null }
    const first = testHttpClient(() => json([entry]))
    const second = testHttpClient(() => json([entry]))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const read = Effect.gen(function* () {
      const session = yield* SessionState
      return yield* session.getTitles('persisted')
    })
    await run(read, first.layer, credLayer)
    const result = await run(read, second.layer, credLayer)
    expect(result).toHaveLength(1)
    expect(second.calls).toHaveLength(0)
  })

  test('noteTitle adds a page the session just created, without refetching', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() =>
      json([{ id: 't1', title: 'A', titleLc: 'a', updated: 1, image: null }]),
    )
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      yield* session.getTitles('noted')
      yield* session.noteTitle('noted', 'B', true)
      yield* session.noteTitle('noted', 'A', false)
      return yield* session.getTitles('noted')
    })
    const titles = await run(program, httpLayer, credLayer)
    expect(titles.map((t) => t.title)).toEqual(['B'])
    expect(calls).toHaveLength(1)
  })

  test('without a credential, returns [] without caching (so a later login can retry)', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() => json([{ title: 'A' }]))
    const { layer: credLayer } = testCredentialStore(Option.none())
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      return yield* session.getTitles('anonymous')
    })
    const result = await run(program, httpLayer, credLayer)
    expect(result).toEqual([])
    expect(calls).toHaveLength(0)
  })
})

describe('SessionState.searchVectorCached (30s TTL, 200-entry cap)', () => {
  test('serves repeated (project, query) calls from cache', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() =>
      json({ pages: [{ title: 'V', score: 1, exists: true }] }),
    )
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      yield* session.searchVectorCached('proj', 'q')
      return yield* session.searchVectorCached('proj', 'q')
    })
    const result = await run(program, httpLayer, credLayer)
    expect(result).toHaveLength(1)
    expect(calls).toHaveLength(1)
  })

  test('refetches once the 30s TTL has elapsed', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() => json({ pages: [] }))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      yield* session.searchVectorCached('proj', 'q')
      yield* TestClock.adjust('31 seconds')
      yield* session.searchVectorCached('proj', 'q')
    })
    await run(program, httpLayer, credLayer)
    expect(calls).toHaveLength(2)
  })

  test('evicts the oldest entry once the cache exceeds 200 entries', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() => json({ pages: [] }))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      // Fill the cache to exactly its cap with 200 distinct queries ('q0'..'q199').
      for (let i = 0; i < 200; i++) yield* session.searchVectorCached('proj', `q${i}`)
      // A 201st distinct query evicts the oldest entry ('q0').
      yield* session.searchVectorCached('proj', 'q200')
      const callsAfterFill = calls.length
      // 'q0' was evicted, so this must be a real fetch (not a cache hit).
      yield* session.searchVectorCached('proj', 'q0')
      // 'q199' — the newest entry from the original fill — was never evicted.
      yield* session.searchVectorCached('proj', 'q199')
      return callsAfterFill
    })
    const callsAfterFill = await run(program, httpLayer, credLayer)
    expect(callsAfterFill).toBe(201)
    expect(calls).toHaveLength(202)
  })
})

describe('SessionState page state', () => {
  test('getPage/setPage/deletePage round-trip by uri', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({}))
    const { layer: credLayer } = testCredentialStore(Option.none())
    const uri = 'cosense://proj/Page'
    const base = {
      project: 'proj',
      title: 'Page',
      baseLines: [{ id: 'l1', text: 'Page' }],
      exists: true,
      pageId: 'pg1',
      commitId: 'c1',
    }
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      const beforeSet = yield* session.getPage(uri)
      yield* session.setPage(uri, base)
      const afterSet = yield* session.getPage(uri)
      yield* session.deletePage(uri)
      const afterDelete = yield* session.getPage(uri)
      return [beforeSet, afterSet, afterDelete] as const
    })
    const [beforeSet, afterSet, afterDelete] = await run(program, httpLayer, credLayer)
    expect(beforeSet).toEqual(Option.none())
    expect(afterSet).toEqual(Option.some(base))
    expect(afterDelete).toEqual(Option.none())
  })
})

describe('SessionState.apiFor', () => {
  test('builds a usable api for an explicit credential even when nothing is cached', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() =>
      json({ id: 'x', name: 'x', displayName: 'x', pageFilters: [] }),
    )
    const { layer: credLayer } = testCredentialStore(Option.none())
    const other: Credential = { type: 'pat', value: 'other-token', source: 'env' }
    const program = Effect.gen(function* () {
      const session = yield* SessionState
      const api = session.apiFor(other)
      return yield* api.me()
    })
    const result = await run(program, httpLayer, credLayer)
    expect(result).toEqual({ id: 'x', name: 'x', displayName: 'x', pageFilters: [] })
    expect(calls).toHaveLength(1)
  })
})
