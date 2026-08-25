import { describe, expect, test } from 'bun:test'
import type { Account, Credential, Me } from '@chatora/core'
import { AccountStore, CredentialStore, HttpClient, KeychainError } from '@chatora/core'
import { Effect, Layer, Option } from 'effect'
import * as handlers from './pages'
import { ReadState } from './readState'
import { makeSessionStateLayer, type SessionState } from './state'

const ORIGIN = 'https://scrapbox.io'
const PAT: Credential = { type: 'pat', value: 'secret-pat', source: 'keychain' }
const ME: Me = { id: 'u1', name: 'qaynam', displayName: 'Qaynam', pageFilters: [] }
const ME_ACCOUNT: Account = {
  id: `${ORIGIN}#${ME.id}`,
  origin: ORIGIN,
  userId: ME.id,
  name: ME.name,
  displayName: ME.displayName,
}

interface Call {
  readonly url: string
  readonly init: RequestInit
}

const testHttpClient = (
  handler: (url: string, init: RequestInit) => Response,
): { layer: Layer.Layer<HttpClient>; calls: Call[] } => {
  const calls: Call[] = []
  const layer = Layer.succeed(
    HttpClient,
    HttpClient.of({
      fetch: (input, init) => {
        calls.push({ url: input, init })
        return Effect.sync(() => handler(input, init))
      },
    }),
  )
  return { layer, calls }
}

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

const testCredentialStore = (
  initial: Option.Option<Credential>,
): {
  layer: Layer.Layer<CredentialStore>
  storeCalls: { origin: string; pat: string }[]
  removeCalls: string[]
} => {
  const storeCalls: { origin: string; pat: string }[] = []
  const removeCalls: string[] = []
  const layer = Layer.succeed(
    CredentialStore,
    CredentialStore.of({
      resolve: () => Effect.succeed(initial),
      store: (origin, pat) => {
        storeCalls.push({ origin, pat })
        return Effect.void
      },
      remove: (origin) => {
        removeCalls.push(origin)
        return Effect.void
      },
    }),
  )
  return { layer, storeCalls, removeCalls }
}

// A stateful fake: add/remove/setActive mutate the same in-memory index that list() reads,
// so a test can chain e.g. addAccount() -> list() the way the real handlers do.
const testAccountStore = (
  seed: { active: Option.Option<string>; accounts: readonly Account[] } = {
    active: Option.none(),
    accounts: [],
  },
): {
  layer: Layer.Layer<AccountStore>
  addCalls: { account: Account; pat: string }[]
  removeCalls: string[]
  setActiveCalls: string[]
} => {
  let state = seed
  const addCalls: { account: Account; pat: string }[] = []
  const removeCalls: string[] = []
  const setActiveCalls: string[] = []
  const layer = Layer.succeed(
    AccountStore,
    AccountStore.of({
      list: () => Effect.succeed(state),
      add: (account, pat) => {
        addCalls.push({ account, pat })
        state = {
          active: Option.some(account.id),
          accounts: [...state.accounts.filter((a) => a.id !== account.id), account],
        }
        return Effect.void
      },
      remove: (id) => {
        removeCalls.push(id)
        const accounts = state.accounts.filter((a) => a.id !== id)
        const wasActive = Option.isSome(state.active) && state.active.value === id
        state = {
          active: wasActive ? Option.fromNullable(accounts[0]?.id) : state.active,
          accounts,
        }
        return Effect.void
      },
      setActive: (id) => {
        setActiveCalls.push(id)
        const account = state.accounts.find((a) => a.id === id)
        if (account === undefined) return Effect.succeed(Option.none())
        state = { ...state, active: Option.some(id) }
        return Effect.succeed(Option.some(account))
      },
      resolveActive: () => Effect.succeed(Option.none()),
    }),
  )
  return { layer, addCalls, removeCalls, setActiveCalls }
}

// Read state is per-run and in-memory here: CHATORA_STATE_DIR points at a throwaway
// directory so a handler test never reads or writes the real one.
const testReadState = (): Layer.Layer<ReadState> =>
  Layer.succeed(ReadState, {
    readAt: () => Effect.succeed(0),
    markRead: () => Effect.void,
  })

const provideAll = <A, E>(
  program: Effect.Effect<A, E, SessionState | HttpClient | AccountStore | ReadState>,
  httpLayer: Layer.Layer<HttpClient>,
  credentialLayer: Layer.Layer<CredentialStore>,
  accountLayer: Layer.Layer<AccountStore> = testAccountStore().layer,
): Effect.Effect<A, E> =>
  program.pipe(
    Effect.provide(httpLayer),
    Effect.provide(accountLayer),
    Effect.provide(testReadState()),
    Effect.provide(makeSessionStateLayer(ORIGIN).pipe(Layer.provide(credentialLayer))),
  )

/** One-shot handler run: each call gets its own SessionState (no cross-call caching). */
const runOnce = <A, E>(
  program: Effect.Effect<A, E, SessionState | HttpClient | AccountStore | ReadState>,
  httpLayer: Layer.Layer<HttpClient>,
  credentialLayer: Layer.Layer<CredentialStore>,
  accountLayer?: Layer.Layer<AccountStore>,
): Promise<A> => Effect.runPromise(provideAll(program, httpLayer, credentialLayer, accountLayer))

describe('authStatus', () => {
  test('no credential -> unauthenticated', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({}))
    const { layer: credLayer } = testCredentialStore(Option.none())
    const result = await runOnce(handlers.authStatus(), httpLayer, credLayer)
    expect(result).toEqual({ ok: true, authenticated: false, origin: ORIGIN })
  })

  test('credential present and verify succeeds -> authenticated with user + source', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() =>
      json({ id: ME.id, name: ME.name, displayName: ME.displayName }),
    )
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const result = await runOnce(handlers.authStatus(), httpLayer, credLayer)
    expect(result).toEqual({
      ok: true,
      authenticated: true,
      origin: ORIGIN,
      source: 'keychain',
      user: ME,
    })
    expect(calls).toHaveLength(1)
  })

  test('credential present but verify fails -> unauthenticated (401)', async () => {
    const { layer: httpLayer } = testHttpClient(() => new Response('nope', { status: 401 }))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const result = await runOnce(handlers.authStatus(), httpLayer, credLayer)
    expect(result).toEqual({ ok: true, authenticated: false, origin: ORIGIN })
  })
})

describe('login', () => {
  test('valid token adds and activates the account via AccountStore', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() =>
      json({ id: ME.id, name: ME.name, displayName: ME.displayName }),
    )
    const { layer: credLayer } = testCredentialStore(Option.none())
    const { layer: accountLayer, addCalls } = testAccountStore()
    const result = await runOnce(handlers.login('typed-pat'), httpLayer, credLayer, accountLayer)
    expect(result).toEqual({
      ok: true,
      authenticated: true,
      origin: ORIGIN,
      source: 'keychain',
      user: ME,
    })
    expect(addCalls).toEqual([{ account: ME_ACCOUNT, pat: 'typed-pat' }])
    expect(calls).toHaveLength(1)
  })

  test('invalid token -> unauthorized "invalid token", nothing added', async () => {
    const { layer: httpLayer } = testHttpClient(() => new Response('no', { status: 401 }))
    const { layer: credLayer } = testCredentialStore(Option.none())
    const { layer: accountLayer, addCalls } = testAccountStore()
    const result = await runOnce(handlers.login('bad-pat'), httpLayer, credLayer, accountLayer)
    expect(result).toEqual({ ok: false, code: 'unauthorized', message: 'invalid token' })
    expect(addCalls).toHaveLength(0)
  })
})

describe('logout', () => {
  test('removes the credential and always reports ok, even if remove fails', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({}))
    const layer = Layer.succeed(
      CredentialStore,
      CredentialStore.of({
        resolve: () => Effect.succeed(Option.none()),
        store: () => Effect.void,
        remove: () => Effect.fail(new KeychainError({ message: 'not found' })),
      }),
    )
    const result = await runOnce(handlers.logout(), httpLayer, layer)
    expect(result).toEqual({ ok: true })
  })

  test('removes the credential at this origin', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({}))
    const { layer: credLayer, removeCalls } = testCredentialStore(Option.some(PAT))
    const result = await runOnce(handlers.logout(), httpLayer, credLayer)
    expect(result).toEqual({ ok: true })
    expect(removeCalls).toEqual([ORIGIN])
  })

  test('removes the active AccountStore account, and still succeeds if that fails', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({}))
    const { layer: credLayer } = testCredentialStore(Option.none())
    const { layer: accountLayer, removeCalls } = testAccountStore({
      active: Option.some(ME_ACCOUNT.id),
      accounts: [ME_ACCOUNT],
    })
    const result = await runOnce(handlers.logout(), httpLayer, credLayer, accountLayer)
    expect(result).toEqual({ ok: true })
    expect(removeCalls).toEqual([ME_ACCOUNT.id])
  })
})

describe('accounts / addAccount / useAccount / removeAccount', () => {
  const OTHER_ACCOUNT: Account = {
    id: `${ORIGIN}#u2`,
    origin: ORIGIN,
    userId: 'u2',
    name: 'qaynam',
    displayName: 'Qaynam',
  }

  test('accounts: reflects the AccountStore index', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({}))
    const { layer: credLayer } = testCredentialStore(Option.none())
    const { layer: accountLayer } = testAccountStore({
      active: Option.some(ME_ACCOUNT.id),
      accounts: [ME_ACCOUNT, OTHER_ACCOUNT],
    })
    const result = await runOnce(handlers.accounts(), httpLayer, credLayer, accountLayer)
    expect(result).toEqual({
      ok: true,
      active: ME_ACCOUNT.id,
      accounts: [ME_ACCOUNT, OTHER_ACCOUNT],
    })
  })

  test('addAccount: valid token adds and activates the account', async () => {
    const { layer: httpLayer } = testHttpClient(() =>
      json({ id: ME.id, name: ME.name, displayName: ME.displayName }),
    )
    const { layer: credLayer } = testCredentialStore(Option.none())
    const { layer: accountLayer, addCalls } = testAccountStore({
      active: Option.some(OTHER_ACCOUNT.id),
      accounts: [OTHER_ACCOUNT],
    })
    const result = await runOnce(
      handlers.addAccount('typed-pat'),
      httpLayer,
      credLayer,
      accountLayer,
    )
    expect(result).toEqual({
      ok: true,
      account: ME_ACCOUNT,
      accounts: [OTHER_ACCOUNT, ME_ACCOUNT],
      active: ME_ACCOUNT.id,
    })
    expect(addCalls).toEqual([{ account: ME_ACCOUNT, pat: 'typed-pat' }])
  })

  test('addAccount: invalid token -> unauthorized, nothing added', async () => {
    const { layer: httpLayer } = testHttpClient(() => new Response('no', { status: 401 }))
    const { layer: credLayer } = testCredentialStore(Option.none())
    const { layer: accountLayer, addCalls } = testAccountStore()
    const result = await runOnce(handlers.addAccount('bad-pat'), httpLayer, credLayer, accountLayer)
    expect(result).toEqual({ ok: false, code: 'unauthorized', message: 'invalid token' })
    expect(addCalls).toHaveLength(0)
  })

  test('useAccount: switches active to a known account', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({}))
    const { layer: credLayer } = testCredentialStore(Option.none())
    const { layer: accountLayer } = testAccountStore({
      active: Option.some(ME_ACCOUNT.id),
      accounts: [ME_ACCOUNT, OTHER_ACCOUNT],
    })
    const result = await runOnce(
      handlers.useAccount({ id: OTHER_ACCOUNT.id }),
      httpLayer,
      credLayer,
      accountLayer,
    )
    expect(result).toEqual({ ok: true, account: OTHER_ACCOUNT, active: OTHER_ACCOUNT.id })
  })

  test('useAccount: unknown id -> error', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({}))
    const { layer: credLayer } = testCredentialStore(Option.none())
    const { layer: accountLayer } = testAccountStore({
      active: Option.some(ME_ACCOUNT.id),
      accounts: [ME_ACCOUNT],
    })
    const result = await runOnce(
      handlers.useAccount({ id: 'unknown-id' }),
      httpLayer,
      credLayer,
      accountLayer,
    )
    expect(result).toEqual({ ok: false, code: 'error', message: 'unknown account' })
  })

  test('removeAccount: removes the account and reports the resulting index', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({}))
    const { layer: credLayer } = testCredentialStore(Option.none())
    const { layer: accountLayer, removeCalls } = testAccountStore({
      active: Option.some(OTHER_ACCOUNT.id),
      accounts: [ME_ACCOUNT, OTHER_ACCOUNT],
    })
    const result = await runOnce(
      handlers.removeAccount({ id: OTHER_ACCOUNT.id }),
      httpLayer,
      credLayer,
      accountLayer,
    )
    expect(result).toEqual({ ok: true, accounts: [ME_ACCOUNT], active: ME_ACCOUNT.id })
    expect(removeCalls).toEqual([OTHER_ACCOUNT.id])
  })
})

describe('projects / listPages', () => {
  test('projects: no credential -> unauthorized "not logged in"', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({}))
    const { layer: credLayer } = testCredentialStore(Option.none())
    const result = await runOnce(handlers.projects(), httpLayer, credLayer)
    expect(result).toEqual({ ok: false, code: 'unauthorized', message: 'not logged in' })
  })

  test('projects: success', async () => {
    const { layer: httpLayer } = testHttpClient(() =>
      json({ projects: [{ id: 'p1', name: 'proj', displayName: 'Proj', pageFilters: [] }] }),
    )
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const result = await runOnce(handlers.projects(), httpLayer, credLayer)
    expect(result.ok).toBe(true)
    if (result.ok) expect(result.projects).toHaveLength(1)
  })

  test('listPages: forwards skip/limit and sorts by updated', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() => json({ count: 0, pages: [] }))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    await runOnce(handlers.listPages({ project: 'proj', skip: 5, limit: 10 }), httpLayer, credLayer)
    expect(calls[0]?.url).toBe(`${ORIGIN}/api/pages/proj/?sort=updated&limit=10&skip=5`)
  })
})

describe('openPage / newPage', () => {
  test('existing page sets base state and returns text/exists/pageId/commitId', async () => {
    const { layer: httpLayer } = testHttpClient(() =>
      json({
        id: 'pg1',
        title: 'My Page',
        commitId: 'c1',
        persistent: true,
        lines: [
          { id: 'l1', text: 'My Page' },
          { id: 'l2', text: 'body' },
        ],
        updated: 1700000000,
        views: 7,
      }),
    )
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const result = await runOnce(
      handlers.openPage({ project: 'proj', title: 'My Page' }),
      httpLayer,
      credLayer,
    )
    expect(result).toEqual({
      ok: true,
      uri: 'cosense://proj/My Page',
      text: 'My Page\nbody',
      exists: true,
      pageId: 'pg1',
      commitId: 'c1',
      // The roster is unreadable in this fixture, which leaves the page writable.
      readOnly: false,
      // Rides along on the open, so the status line and the info panel never need a
      // second round-trip.
      meta: {
        created: 0,
        updated: 1700000000,
        accessed: 0,
        views: 7,
        linked: 0,
        linesCount: 0,
        charsCount: 0,
        pin: 0,
        pageRank: 0,
        snapshotCount: 0,
      },
    })
  })

  test('non-existent page (persistent:false) opens empty with exists:false', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({ persistent: false }))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const result = await runOnce(
      handlers.newPage({ project: 'proj', title: 'New Page' }),
      httpLayer,
      credLayer,
    )
    expect(result).toEqual({
      ok: true,
      uri: 'cosense://proj/New Page',
      text: 'New Page',
      exists: false,
      readOnly: false,
    })
  })
})

describe('savePage', () => {
  test('document not synced -> error', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({}))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const result = await runOnce(
      handlers.savePage('cosense://proj/Missing', undefined),
      httpLayer,
      credLayer,
    )
    expect(result).toEqual({ ok: false, code: 'error', message: 'document not synced' })
  })

  test('no tracked base state -> error asking to reopen', async () => {
    const { layer: httpLayer } = testHttpClient(() => json({}))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const result = await runOnce(
      handlers.savePage('cosense://proj/Untracked', 'text\n'),
      httpLayer,
      credLayer,
    )
    expect(result).toEqual({
      ok: false,
      code: 'error',
      message: 'page state not found; reopen the page',
    })
  })

  test('no changes -> noop with the existing commitId', async () => {
    const { layer: httpLayer } = testHttpClient(() =>
      json({
        id: 'pg1',
        title: 'Page',
        commitId: 'c1',
        persistent: true,
        lines: [{ id: 'l1', text: 'Page' }],
      }),
    )
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      yield* handlers.openPage({ project: 'proj', title: 'Page' })
      return yield* handlers.savePage('cosense://proj/Page', 'Page\n')
    })
    const result = await runOnce(program, httpLayer, credLayer)
    expect(result).toEqual({ ok: true, commitId: 'c1', noop: true })
  })

  test('full flow: preview -> submit -> refetch, correct RawChange, base state re-keyed', async () => {
    let submitted = false
    const { layer: httpLayer, calls } = testHttpClient((url) => {
      if (url.endsWith('/page-edit-for-ai/preview')) {
        return json({ previewId: 'pv1', expireAt: 'later', pagePreview: null })
      }
      if (url.endsWith('/page-edit-for-ai/submit')) {
        submitted = true
        return json({ commitId: 'c2', page: { title: 'Page' } })
      }
      return json({
        id: 'pg1',
        title: 'Page',
        commitId: submitted ? 'c2' : 'c1',
        persistent: true,
        lines: submitted
          ? [
              { id: 'l1', text: 'Page' },
              { id: 'l2', text: 'new line' },
            ]
          : [{ id: 'l1', text: 'Page' }],
      })
    })
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      yield* handlers.openPage({ project: 'proj', title: 'Page' })
      return yield* handlers.savePage('cosense://proj/Page', 'Page\nnew line\n')
    })
    const result = await runOnce(program, httpLayer, credLayer)
    expect(result).toEqual({ ok: true, commitId: 'c2' })

    const previewCall = calls.find((c) => c.url.endsWith('/preview'))
    const body = JSON.parse(previewCall?.init.body as string) as {
      pageId?: string
      changes: readonly { _insert: string; lines: { id: string; text: string } }[]
    }
    expect(body.pageId).toBe('pg1')
    expect(body.changes).toHaveLength(1)
    expect(body.changes[0]?._insert).toBe('_end')
    expect(body.changes[0]?.lines.text).toBe('new line')
    expect(/^[0-9a-f]{24}$/.test(body.changes[0]?.lines.id ?? '')).toBe(true)

    const submitCall = calls.find((c) => c.url.endsWith('/submit'))
    expect(JSON.parse(submitCall?.init.body as string)).toEqual({ previewId: 'pv1' })
  })

  test('a 409 NotFastForward preview conflict maps to code "notFastForward"', async () => {
    const { layer: httpLayer } = testHttpClient((url) => {
      if (url.endsWith('/page-edit-for-ai/preview')) return json({ error: 'NotFastForward' }, 409)
      return json({
        id: 'pg1',
        title: 'Page',
        commitId: 'c1',
        persistent: true,
        lines: [{ id: 'l1', text: 'Page' }],
      })
    })
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      yield* handlers.openPage({ project: 'proj', title: 'Page' })
      return yield* handlers.savePage('cosense://proj/Page', 'Page\nnew line\n')
    })
    const result = await runOnce(program, httpLayer, credLayer)
    expect(result).toEqual({
      ok: false,
      code: 'notFastForward',
      message: 'remote page has changed; reload and try again',
    })
  })
})

describe('error mapping', () => {
  test('a 401 from the API maps to code "unauthorized"', async () => {
    const { layer: httpLayer } = testHttpClient(() => new Response('nope', { status: 401 }))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const result = await runOnce(handlers.projects(), httpLayer, credLayer)
    expect(result).toEqual({ ok: false, code: 'unauthorized', message: 'authentication failed' })
  })

  test('an unrecognized failure forwards CosenseApiError.message as code "error"', async () => {
    const { layer: httpLayer } = testHttpClient(() => new Response('boom', { status: 500 }))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const result = await runOnce(handlers.projects(), httpLayer, credLayer)
    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.code).toBe('error')
      expect(result.message).not.toContain(PAT.value)
    }
  })
})

describe('relatedPages / search', () => {
  test('relatedPages: success merges links1hop/links2hop', async () => {
    const { layer: httpLayer } = testHttpClient((url) => {
      if (url.endsWith('/links1hop')) return json({ links1hop: [{ id: 'a', title: 'A' }] })
      return json({ links2hop: [] })
    })
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const result = await runOnce(
      handlers.relatedPages({ project: 'proj', title: 'Page' }),
      httpLayer,
      credLayer,
    )
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.links1hop).toHaveLength(1)
      expect(result.links2hop).toHaveLength(0)
    }
  })

  test('search: fulltext mode includes lines, vector mode does not', async () => {
    const { layer: httpLayer } = testHttpClient((url) => {
      if (url.includes('/search/vector/')) return json({ pages: [{ title: 'V', exists: true }] })
      return json({
        count: 1,
        existsExactTitleMatch: false,
        pages: [{ title: 'F', lines: ['a', 'b'] }],
      })
    })
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const fulltext = await runOnce(
      handlers.search({ project: 'proj', query: 'q' }),
      httpLayer,
      credLayer,
    )
    const vector = await runOnce(
      handlers.search({ project: 'proj', query: 'q', mode: 'vector' }),
      httpLayer,
      credLayer,
    )
    expect(fulltext).toEqual({ ok: true, pages: [{ title: 'F', lines: ['a', 'b'] }] })
    expect(vector).toEqual({ ok: true, pages: [{ title: 'V' }] })
  })
})

describe('listPages unread flag', () => {
  test('unread is updated > accessed; a never-visited page counts as unread', async () => {
    const { layer: httpLayer } = testHttpClient(() =>
      json({
        count: 3,
        pages: [
          { id: 'a', title: 'edited since my last visit', updated: 200, accessed: 100 },
          { id: 'b', title: 'seen after its last edit', updated: 100, accessed: 200 },
          { id: 'c', title: 'never visited', updated: 100 },
        ],
      }),
    )
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const result = await runOnce(handlers.listPages({ project: 'proj' }), httpLayer, credLayer)
    expect(result.ok).toBe(true)
    if (result.ok) {
      expect(result.pages.map((p) => p.unread)).toEqual([true, false, true])
    }
  })
})

// A page the server has moved on from, served as `before` until the first preview is
// rejected and `after` from then on — the shape every conflict path below starts from.
const racingPage = (
  before: readonly { id: string; text: string }[],
  after: readonly { id: string; text: string }[],
  opts: {
    readonly rejectSecondPreview?: boolean
    /** What the page holds once the retried save lands. */
    readonly settled?: readonly { id: string; text: string }[]
  } = {},
) => {
  let previews = 0
  let submitted = false
  return testHttpClient((url) => {
    if (url.endsWith('/page-edit-for-ai/preview')) {
      previews++
      if (previews === 1 || opts.rejectSecondPreview) return json({ error: 'NotFastForward' }, 409)
      return json({ previewId: 'pv2', expireAt: 'later', pagePreview: null })
    }
    if (url.endsWith('/page-edit-for-ai/submit')) {
      submitted = true
      return json({ commitId: 'c3', page: { title: 'Page' } })
    }
    return json({
      id: 'pg1',
      title: 'Page',
      commitId: previews === 0 ? 'c1' : 'c2',
      persistent: true,
      lines: submitted ? (opts.settled ?? after) : previews === 0 ? before : after,
    })
  })
}

const BEFORE = [
  { id: 'l1', text: 'Page' },
  { id: 'l2', text: 'alpha' },
]

describe('savePage conflict recovery', () => {
  test('a remote edit elsewhere is merged in and the save goes through', async () => {
    const after = [...BEFORE, { id: 'l3', text: 'theirs' }]
    const settled = [...after, { id: 'l4', text: 'mine' }]
    const { layer: httpLayer, calls } = racingPage(BEFORE, after, { settled })
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      yield* handlers.openPage({ project: 'proj', title: 'Page' })
      return yield* handlers.savePage('cosense://proj/Page', 'Page\nalpha\nmine\n')
    })
    const result = (await runOnce(program, httpLayer, credLayer)) as { ok: boolean; text?: string }

    expect(result.ok).toBe(true)
    // Both sides' lines are in the saved text, and the client is handed it: the buffer
    // still holds the pre-merge lines and has to be brought up to the merge.
    expect(result.text).toBe('Page\nalpha\ntheirs\nmine')
    expect(calls.filter((c) => c.url.endsWith('/preview'))).toHaveLength(2)

    const retry = calls.filter((c) => c.url.endsWith('/preview'))[1]
    const body = JSON.parse(retry?.init.body as string) as {
      changes: readonly { _insert?: string; lines?: { text: string } }[]
    }
    // Rebuilt against the refetched lines, so it adds the local line and nothing else.
    expect(body.changes).toHaveLength(1)
    expect(body.changes[0]?.lines?.text).toBe('mine')
  })

  test('the same line edited on both sides refuses the save and keeps the local text', async () => {
    const after = [
      { id: 'l1', text: 'Page' },
      { id: 'l2', text: 'theirs' },
    ]
    const { layer: httpLayer, calls } = racingPage(BEFORE, after)
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      yield* handlers.openPage({ project: 'proj', title: 'Page' })
      return yield* handlers.savePage('cosense://proj/Page', 'Page\nmine\n')
    })
    const result = (await runOnce(program, httpLayer, credLayer)) as {
      ok: boolean
      code?: string
      text?: string
      conflicts?: readonly { line: number; ours: string; theirs: string; base: string }[]
    }

    expect(result.ok).toBe(false)
    expect(result.code).toBe('conflict')
    expect(result.text).toBe('Page\nmine')
    expect(result.conflicts).toEqual([{ line: 1, ours: 'mine', theirs: 'theirs', base: 'alpha' }])
    // Nothing was written: a conflict stops at the merge, before a second preview.
    expect(calls.filter((c) => c.url.endsWith('/submit'))).toHaveLength(0)
    expect(calls.filter((c) => c.url.endsWith('/preview'))).toHaveLength(1)
  })

  test('a retry that races again reports notFastForward rather than looping', async () => {
    const after = [...BEFORE, { id: 'l3', text: 'theirs' }]
    const { layer: httpLayer, calls } = racingPage(BEFORE, after, { rejectSecondPreview: true })
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      yield* handlers.openPage({ project: 'proj', title: 'Page' })
      return yield* handlers.savePage('cosense://proj/Page', 'Page\nalpha\nmine\n')
    })
    const result = await runOnce(program, httpLayer, credLayer)
    expect(result).toMatchObject({ ok: false, code: 'notFastForward' })
    expect(calls.filter((c) => c.url.endsWith('/preview'))).toHaveLength(2)
  })
})

describe('syncPage', () => {
  test('a remote change reaches an untouched buffer', async () => {
    let latest = BEFORE
    const { layer: httpLayer } = testHttpClient(() =>
      json({ id: 'pg1', title: 'Page', commitId: 'c1', persistent: true, lines: latest }),
    )
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      yield* handlers.openPage({ project: 'proj', title: 'Page' })
      latest = [...BEFORE, { id: 'l3', text: 'theirs' }]
      return yield* handlers.syncPage('cosense://proj/Page', 'Page\nalpha\n')
    })
    expect(await runOnce(program, httpLayer, credLayer)).toMatchObject({
      ok: true,
      changed: true,
      text: 'Page\nalpha\ntheirs',
      conflicts: [],
    })
  })

  test('unsaved local edits survive the merge', async () => {
    let latest = BEFORE
    const { layer: httpLayer } = testHttpClient(() =>
      json({ id: 'pg1', title: 'Page', commitId: 'c1', persistent: true, lines: latest }),
    )
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      yield* handlers.openPage({ project: 'proj', title: 'Page' })
      latest = [...BEFORE, { id: 'l3', text: 'theirs' }]
      return yield* handlers.syncPage('cosense://proj/Page', 'Page\nalpha\nmine\n')
    })
    const result = (await runOnce(program, httpLayer, credLayer)) as { text: string }
    expect(result.text.split('\n')).toContain('mine')
    expect(result.text.split('\n')).toContain('theirs')
  })

  test('a line both sides changed is reported, with the local text left in place', async () => {
    let latest = BEFORE
    const { layer: httpLayer } = testHttpClient(() =>
      json({ id: 'pg1', title: 'Page', commitId: 'c1', persistent: true, lines: latest }),
    )
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      yield* handlers.openPage({ project: 'proj', title: 'Page' })
      latest = [
        { id: 'l1', text: 'Page' },
        { id: 'l2', text: 'theirs' },
      ]
      return yield* handlers.syncPage('cosense://proj/Page', 'Page\nmine\n')
    })
    expect(await runOnce(program, httpLayer, credLayer)).toMatchObject({
      ok: true,
      text: 'Page\nmine',
      conflicts: [{ line: 1, ours: 'mine', theirs: 'theirs', base: 'alpha' }],
    })
  })

  test('the fetched lines become the base, so the next save carries only what is left', async () => {
    let latest = BEFORE
    let previewBody: string | undefined
    const { layer: httpLayer } = testHttpClient((url, init) => {
      if (url.endsWith('/page-edit-for-ai/preview')) {
        previewBody = init.body as string
        return json({ previewId: 'pv1', expireAt: 'later', pagePreview: null })
      }
      if (url.endsWith('/page-edit-for-ai/submit')) {
        return json({ commitId: 'c3', page: { title: 'Page' } })
      }
      return json({ id: 'pg1', title: 'Page', commitId: 'c2', persistent: true, lines: latest })
    })
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      yield* handlers.openPage({ project: 'proj', title: 'Page' })
      latest = [...BEFORE, { id: 'l3', text: 'theirs' }]
      yield* handlers.syncPage('cosense://proj/Page', 'Page\nalpha\nmine\n')
      return yield* handlers.savePage('cosense://proj/Page', 'Page\nalpha\ntheirs\nmine\n')
    })
    await runOnce(program, httpLayer, credLayer)
    const body = JSON.parse(previewBody as string) as { changes: readonly unknown[] }
    // Only the local line is new; 'theirs' is already the server's and must not be re-sent.
    expect(body.changes).toHaveLength(1)
  })

  test('a page deleted on the server leaves the buffer as the only copy', async () => {
    let exists = true
    const { layer: httpLayer } = testHttpClient(() =>
      exists
        ? json({ id: 'pg1', title: 'Page', commitId: 'c1', persistent: true, lines: BEFORE })
        : json({ message: 'not found' }, 404),
    )
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      yield* handlers.openPage({ project: 'proj', title: 'Page' })
      exists = false
      return yield* handlers.syncPage('cosense://proj/Page', 'Page\nalpha\nmine\n')
    })
    expect(await runOnce(program, httpLayer, credLayer)).toMatchObject({
      ok: true,
      changed: false,
      text: 'Page\nalpha\nmine',
    })
  })
})

describe('openPage read-only', () => {
  const page = {
    id: 'pg1',
    title: 'Page',
    commitId: 'c1',
    persistent: true,
    lines: [{ id: 'l1', text: 'Page' }],
  }
  // `/api/users/me` and `/api/projects/<name>/users` both end in "users", so the account
  // route has to be matched first or verification gets handed the roster.
  const serve = (roster: unknown) =>
    testHttpClient((url) => {
      if (url.endsWith('/api/users/me')) return json(ME)
      return url.endsWith('/users') ? json(roster) : json(page)
    })

  test('a project whose roster does not list this user is read-only', async () => {
    const { layer: httpLayer } = serve({ projectId: 'p1', users: [{ id: 'someone-else' }] })
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      // The read-only check compares against the verified user, so verify first.
      yield* handlers.authStatus()
      return yield* handlers.openPage({ project: 'other', title: 'Page' })
    })
    expect(await runOnce(program, httpLayer, credLayer)).toMatchObject({ readOnly: true })
  })

  test('a project this user belongs to is writable', async () => {
    const { layer: httpLayer } = serve({ projectId: 'p1', users: [{ id: ME.id }] })
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      yield* handlers.authStatus()
      return yield* handlers.openPage({ project: 'mine', title: 'Page' })
    })
    expect(await runOnce(program, httpLayer, credLayer)).toMatchObject({ readOnly: false })
  })

  // Locking a buffer the user can in fact edit is the worse mistake: a refused save
  // explains itself, an editor that will not take a keystroke does not.
  test('an unreadable roster leaves the page writable', async () => {
    const { layer: httpLayer } = testHttpClient((url) => {
      if (url.endsWith('/api/users/me')) return json(ME)
      return url.endsWith('/users') ? json({ message: 'nope' }, 401) : json(page)
    })
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const program = Effect.gen(function* () {
      yield* handlers.authStatus()
      return yield* handlers.openPage({ project: 'unknown', title: 'Page' })
    })
    expect(await runOnce(program, httpLayer, credLayer)).toMatchObject({ readOnly: false })
  })
})
