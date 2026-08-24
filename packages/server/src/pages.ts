import type {
  Account,
  CosenseApiError,
  Credential,
  HttpClient,
  KeychainError,
  Me,
  PageFilter,
  PageSummary,
  ProjectSummary,
  RelatedPage,
  SearchResultPage,
} from '@chatora/core'
import { AccountStore, computeChanges, createNewLineId } from '@chatora/core'
import { Effect, Option } from 'effect'
import { textToLines } from './lines'
import { type BasePageState, SessionState } from './state'
import { formatUri } from './uriScheme'

export type ErrCode = 'unauthorized' | 'notFastForward' | 'error'
export interface ErrEnvelope {
  readonly ok: false
  readonly code: ErrCode
  readonly message: string
}

const err = (code: ErrCode, message: string): ErrEnvelope => ({ ok: false, code, message })
const noCredential = (): ErrEnvelope => err('unauthorized', 'not logged in')

const UNAUTHORIZED_STATUSES: ReadonlySet<number> = new Set([401, 403])

/**
 * Maps a CosenseApiError to the `chatora/*` wire error contract (docs/ARCHITECTURE.md):
 * 401/403 -> unauthorized, the page-edit optimistic-lock conflict -> notFastForward,
 * everything else forwards CosenseApiError's own message as-is — it's already
 * credential-safe (built server-side in @chatora/core's api.ts from status/statusText only).
 */
const fromCosenseApiError = (error: CosenseApiError): ErrEnvelope => {
  if (UNAUTHORIZED_STATUSES.has(error.status)) return err('unauthorized', 'authentication failed')
  if (error.code === 'NotFastForward') {
    return err('notFastForward', 'remote page has changed; reload and try again')
  }
  return err('error', error.message)
}

/**
 * Every chatora/* handler ends with this: the two failure channels @chatora/core exposes to
 * server code (CosenseApiError from API calls, KeychainError from credential storage) both
 * become the `{ok:false,...}` wire envelope instead of an LSP-level error; a success value
 * passes through untouched.
 */
const handle = <A, R>(
  effect: Effect.Effect<A, CosenseApiError | KeychainError, R>,
): Effect.Effect<A | ErrEnvelope, never, R> =>
  effect.pipe(
    Effect.catchTag('CosenseApiError', (error) => Effect.succeed(fromCosenseApiError(error))),
    Effect.catchTag('KeychainError', (error) => Effect.succeed(err('error', error.message))),
  )

// ---------------------------------------------------------------------------
// auth
// ---------------------------------------------------------------------------

export interface AuthStatusResult {
  readonly ok: true
  readonly authenticated: boolean
  readonly origin: string
  readonly source?: Credential['source']
  readonly user?: {
    readonly id: string
    readonly name: string
    readonly displayName: string
    readonly pageFilters: readonly PageFilter[]
  }
}

// pageFilters travels with the user so the sidebar can build a tab per saved
// Cosense filter without a second round-trip.
const toUserRef = (user: Me) => ({
  id: user.id,
  name: user.name,
  displayName: user.displayName,
  pageFilters: user.pageFilters,
})

// Account.id doubles as the multi-account Keychain lookup key (docs/ARCHITECTURE.md), so
// login and addAccount — which both turn a freshly-verified PAT into a stored account —
// build it the same way.
const buildAccount = (origin: string, user: Me): Account => ({
  id: `${origin}#${user.id}`,
  origin,
  userId: user.id,
  name: user.name,
  displayName: user.displayName,
  ...(user.photo !== undefined ? { photo: user.photo } : {}),
})

export const authStatus = (): Effect.Effect<
  AuthStatusResult | ErrEnvelope,
  never,
  SessionState | HttpClient
> =>
  handle(
    Effect.gen(function* () {
      const session = yield* SessionState
      const credentialOpt = yield* session.getCredential()
      if (Option.isNone(credentialOpt)) {
        return { ok: true as const, authenticated: false as const, origin: session.origin }
      }
      const userOpt = yield* session.ensureVerified()
      if (Option.isNone(userOpt)) {
        return { ok: true as const, authenticated: false as const, origin: session.origin }
      }
      return {
        ok: true as const,
        authenticated: true as const,
        origin: session.origin,
        source: credentialOpt.value.source,
        user: toUserRef(userOpt.value),
      }
    }),
  )

// login is an alias for "add this account and make it active": both verify the PAT once,
// then hand the resulting account to AccountStore.add, which is what actually persists it
// (Keychain entry keyed by Account.id + the accounts.json index) and marks it active.
export const login = (
  pat: string,
): Effect.Effect<AuthStatusResult | ErrEnvelope, never, SessionState | HttpClient | AccountStore> =>
  Effect.gen(function* () {
    const session = yield* SessionState
    const credential: Credential = { type: 'pat', value: pat, source: 'keychain' }
    const api = session.apiFor(credential)
    // A fresh, uncached verification: any failure (bad token, network, ...) is reported as
    // one generic "invalid token" rather than routed through fromCosenseApiError's
    // status-specific mapping, matching a login form's single failure mode.
    const verified = yield* api.me().pipe(Effect.option)
    if (Option.isNone(verified)) return err('unauthorized', 'invalid token')
    const user = verified.value

    return yield* handle(
      Effect.gen(function* () {
        const accountStore = yield* AccountStore
        yield* accountStore.add(buildAccount(session.origin, user), pat)
        yield* session.invalidateCredentials()
        yield* session.setVerifiedUser(user)
        return {
          ok: true as const,
          authenticated: true as const,
          origin: session.origin,
          source: 'keychain' as const,
          user: toUserRef(user),
        }
      }),
    )
  })

// Best-effort like the pre-multi-account logout it replaces: every delete below is allowed
// to fail (missing item, non-darwin, ...) without turning logout itself into a failure.
export const logout = (): Effect.Effect<
  { readonly ok: true },
  never,
  SessionState | AccountStore
> =>
  Effect.gen(function* () {
    const session = yield* SessionState
    const accountStore = yield* AccountStore
    const { active } = yield* accountStore.list()
    if (Option.isSome(active)) {
      yield* accountStore.remove(active.value).pipe(Effect.catchAll(() => Effect.void))
    }
    // The legacy origin-keyed entry predates AccountStore; removing it too keeps a
    // pre-multi-account user fully logged out.
    yield* session.removeCredential().pipe(Effect.catchAll(() => Effect.void))
    yield* session.invalidateCredentials()
    return { ok: true as const }
  })

// ---------------------------------------------------------------------------
// multi-account
// ---------------------------------------------------------------------------

export interface AccountsResult {
  readonly ok: true
  readonly active: string | null
  readonly accounts: readonly Account[]
}

export const accounts = (): Effect.Effect<AccountsResult, never, AccountStore> =>
  Effect.gen(function* () {
    const store = yield* AccountStore
    const { active, accounts: list } = yield* store.list()
    return { ok: true as const, active: Option.getOrNull(active), accounts: list }
  })

export interface AddAccountResult {
  readonly ok: true
  readonly account: Account
  readonly accounts: readonly Account[]
  readonly active: string | null
}

export const addAccount = (
  pat: string,
): Effect.Effect<AddAccountResult | ErrEnvelope, never, SessionState | HttpClient | AccountStore> =>
  Effect.gen(function* () {
    const session = yield* SessionState
    const credential: Credential = { type: 'pat', value: pat, source: 'keychain' }
    const api = session.apiFor(credential)
    const verified = yield* api.me().pipe(Effect.option)
    if (Option.isNone(verified)) return err('unauthorized', 'invalid token')
    const user = verified.value
    const account = buildAccount(session.origin, user)

    return yield* handle(
      Effect.gen(function* () {
        const store = yield* AccountStore
        yield* store.add(account, pat)
        yield* session.invalidateCredentials()
        yield* session.setVerifiedUser(user)
        const { active, accounts: list } = yield* store.list()
        return { ok: true as const, account, accounts: list, active: Option.getOrNull(active) }
      }),
    )
  })

export interface UseAccountResult {
  readonly ok: true
  readonly account: Account
  readonly active: string | null
}

export const useAccount = (params: {
  readonly id: string
}): Effect.Effect<UseAccountResult | ErrEnvelope, never, SessionState | AccountStore> =>
  Effect.gen(function* () {
    const session = yield* SessionState
    const store = yield* AccountStore
    const accountOpt = yield* store.setActive(params.id)
    if (Option.isNone(accountOpt)) return err('error', 'unknown account')
    yield* session.invalidateCredentials()
    return { ok: true as const, account: accountOpt.value, active: params.id }
  })

export interface RemoveAccountResult {
  readonly ok: true
  readonly accounts: readonly Account[]
  readonly active: string | null
}

export const removeAccount = (params: {
  readonly id: string
}): Effect.Effect<RemoveAccountResult | ErrEnvelope, never, SessionState | AccountStore> =>
  handle(
    Effect.gen(function* () {
      const session = yield* SessionState
      const store = yield* AccountStore
      yield* store.remove(params.id)
      yield* session.invalidateCredentials()
      const { active, accounts: list } = yield* store.list()
      return { ok: true as const, accounts: list, active: Option.getOrNull(active) }
    }),
  )

// ---------------------------------------------------------------------------
// projects / pages
// ---------------------------------------------------------------------------

export const projects = (): Effect.Effect<
  { readonly ok: true; readonly projects: readonly ProjectSummary[] } | ErrEnvelope,
  never,
  SessionState | HttpClient
> =>
  handle(
    Effect.gen(function* () {
      const session = yield* SessionState
      const apiOpt = yield* session.getApi()
      if (Option.isNone(apiOpt)) return noCredential()
      const list = yield* apiOpt.value.projects()
      return { ok: true as const, projects: list }
    }),
  )

/** A listed page plus the unread flag the Lua sidebar renders. */
export type ListedPage = PageSummary & { readonly unread: boolean }

/**
 * Cosense has no unread flag of its own: its web grid draws the blue border from
 * `updated > accessed`, and so does this. A page never visited has `accessed` 0, which makes
 * it unread — matching the web UI, where everything starts unread.
 */
const withUnread = (page: PageSummary): ListedPage => ({
  ...page,
  unread: page.updated > page.accessed,
})

export const listPages = (params: {
  readonly project: string
  readonly skip?: number
  readonly limit?: number
  readonly filterType?: string
  readonly filterValue?: string
  readonly unreadOnly?: boolean
}): Effect.Effect<
  | {
      readonly ok: true
      /** Total pages the *unfiltered* query would return, straight from Cosense. */
      readonly count: number
      readonly pages: readonly ListedPage[]
      /** Pages in this batch before `unreadOnly` dropped any — how far `skip` really advanced. */
      readonly scanned: number
    }
  | ErrEnvelope,
  never,
  SessionState | HttpClient
> =>
  handle(
    Effect.gen(function* () {
      const session = yield* SessionState
      const apiOpt = yield* session.getApi()
      if (Option.isNone(apiOpt)) return noCredential()
      const opts: {
        skip?: number
        limit?: number
        sort: string
        filterType?: string
        filterValue?: string
      } = { sort: 'updated' }
      if (params.skip !== undefined) opts.skip = params.skip
      if (params.limit !== undefined) opts.limit = params.limit
      if (params.filterType !== undefined) opts.filterType = params.filterType
      if (params.filterValue !== undefined) opts.filterValue = params.filterValue

      const result = yield* apiOpt.value.listPages(params.project, opts)
      const listed = result.pages.map(withUnread)
      // Unread has no server-side filter, so it thins a batch client-side and
      // the caller pages on `scanned` rather than on how many pages it got.
      const pages = params.unreadOnly ? listed.filter((p) => p.unread) : listed
      return { ok: true as const, count: result.count, pages, scanned: listed.length }
    }),
  )

export interface OpenPageResult {
  readonly ok: true
  readonly uri: string
  readonly text: string
  readonly exists: boolean
  readonly pageId?: string
  readonly commitId?: string
}

export const openPage = (params: {
  readonly project: string
  readonly title: string
}): Effect.Effect<OpenPageResult | ErrEnvelope, never, SessionState | HttpClient> =>
  handle(
    Effect.gen(function* () {
      const session = yield* SessionState
      const apiOpt = yield* session.getApi()
      if (Option.isNone(apiOpt)) return noCredential()
      const uri = formatUri(params.project, params.title)
      const pageOpt = yield* apiOpt.value.getPage(params.project, params.title)

      if (Option.isSome(pageOpt)) {
        const page = pageOpt.value
        const text = page.lines.map((l) => l.text).join('\n')
        // Opening a page is what marks it read. Forked so a slow (or missing)
        // accessed endpoint never delays showing the page.
        yield* Effect.forkDaemon(apiOpt.value.markAccessed(params.project, page.id))
        yield* session.setPage(uri, {
          project: params.project,
          title: params.title,
          pageId: page.id,
          commitId: page.commitId,
          baseLines: page.lines,
          exists: true,
        })
        return {
          ok: true as const,
          uri,
          text,
          exists: true as const,
          pageId: page.id,
          commitId: page.commitId,
        }
      }

      yield* session.setPage(uri, {
        project: params.project,
        title: params.title,
        baseLines: [],
        exists: false,
      })
      return { ok: true as const, uri, text: params.title, exists: false as const }
    }),
  )

// `chatora/newPage` is a plain alias — the Lua side may call either.
export const newPage = openPage

// ---------------------------------------------------------------------------
// savePage
// ---------------------------------------------------------------------------

export interface SavePageResult {
  readonly ok: true
  readonly commitId: string
  readonly noop?: true
  readonly text?: string
  readonly titleChanged?: { readonly from: string; readonly to: string }
}

/**
 * `docText` is the synced document text (or `undefined` when the uri has no open document) —
 * looked up from `TextDocuments` at the LSP edge in main.ts, since that lookup is plain
 * connection state, not something this Effect program needs to depend on.
 */
export const savePage = (
  uri: string,
  docText: string | undefined,
): Effect.Effect<SavePageResult | ErrEnvelope, never, SessionState | HttpClient> =>
  handle(
    Effect.gen(function* () {
      if (docText === undefined) return err('error', 'document not synced')

      const session = yield* SessionState
      const baseOpt = yield* session.getPage(uri)
      if (Option.isNone(baseOpt)) return err('error', 'page state not found; reopen the page')
      const base = baseOpt.value

      const apiOpt = yield* session.getApi()
      if (Option.isNone(apiOpt)) return noCredential()
      const api = apiOpt.value

      const nextLines = textToLines(docText)
      const userId = yield* session.verifiedUserId()
      const changes = computeChanges(base.baseLines, nextLines, () => createNewLineId(userId))

      if (changes.length === 0) {
        return { ok: true as const, commitId: base.commitId ?? '', noop: true as const }
      }

      const preview = yield* api.previewEdit(
        base.project,
        base.pageId !== undefined ? { pageId: base.pageId, changes } : { changes },
      )
      const submit = yield* api.submitEdit(base.project, preview.previewId)

      const finalTitle = submit.page?.title ?? submit.titleChanged?.to ?? base.title
      // refetched should be non-null right after a successful submit; falling back to what
      // we just sent keeps savePage well-defined even if the server races us on this read.
      const refetchedOpt = yield* api.getPage(base.project, finalTitle)
      const submittedText = nextLines.join('\n')
      const responseText = Option.match(refetchedOpt, {
        onNone: () => undefined,
        onSome: (refetched) => {
          const text = refetched.lines.map((l) => l.text).join('\n')
          return text !== submittedText ? text : undefined
        },
      })

      const newBase: BasePageState = Option.match(refetchedOpt, {
        onSome: (refetched): BasePageState => ({
          project: base.project,
          title: finalTitle,
          baseLines: refetched.lines,
          exists: true,
          pageId: refetched.id,
          commitId: refetched.commitId,
        }),
        onNone: (): BasePageState => ({
          project: base.project,
          title: finalTitle,
          baseLines: base.baseLines,
          exists: true,
          ...(base.pageId !== undefined ? { pageId: base.pageId } : {}),
          commitId: submit.commitId,
        }),
      })

      const newUri = formatUri(base.project, finalTitle)
      if (newUri !== uri) yield* session.deletePage(uri)
      yield* session.setPage(newUri, newBase)

      return {
        ok: true as const,
        commitId: newBase.commitId ?? '',
        ...(responseText !== undefined ? { text: responseText } : {}),
        ...(submit.titleChanged !== undefined ? { titleChanged: submit.titleChanged } : {}),
      }
    }),
  )

// ---------------------------------------------------------------------------
// related pages / search
// ---------------------------------------------------------------------------

export const relatedPages = (params: {
  readonly project: string
  readonly title: string
}): Effect.Effect<
  | {
      readonly ok: true
      readonly links1hop: readonly RelatedPage[]
      readonly links2hop: readonly RelatedPage[]
    }
  | ErrEnvelope,
  never,
  SessionState | HttpClient
> =>
  handle(
    Effect.gen(function* () {
      const session = yield* SessionState
      const apiOpt = yield* session.getApi()
      if (Option.isNone(apiOpt)) return noCredential()
      const result = yield* apiOpt.value.relatedPages(params.project, params.title)
      return { ok: true as const, links1hop: result.links1hop, links2hop: result.links2hop }
    }),
  )

export const search = (params: {
  readonly project: string
  readonly query: string
  readonly mode?: 'fulltext' | 'vector'
}): Effect.Effect<
  | {
      readonly ok: true
      readonly pages: readonly { readonly title: string; readonly lines?: readonly string[] }[]
    }
  | ErrEnvelope,
  never,
  SessionState | HttpClient
> =>
  handle(
    Effect.gen(function* () {
      const session = yield* SessionState
      const apiOpt = yield* session.getApi()
      if (Option.isNone(apiOpt)) return noCredential()
      const api = apiOpt.value

      if (params.mode === 'vector') {
        const result = yield* api.searchVector(params.project, params.query)
        return { ok: true as const, pages: result.pages.map((p) => ({ title: p.title })) }
      }

      const result: { readonly pages: readonly SearchResultPage[] } = yield* api.searchFullText(
        params.project,
        params.query,
      )
      return {
        ok: true as const,
        pages: result.pages.map((p) => ({ title: p.title, lines: p.lines })),
      }
    }),
  )
