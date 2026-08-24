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
