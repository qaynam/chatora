import type {
  Account,
  CosenseApiError,
  Credential,
  HttpClient,
  KeychainError,
  Me,
  MergeConflict,
  PageDetail,
  PageDetailLine,
  PageFilter,
  PageSummary,
  ProjectSummary,
  RelatedPage,
  SearchResultPage,
  SubmitResponse,
  TitleEntry,
} from '@chatora/core'
import { AccountStore, computeChanges, createNewLineId, mergeThreeWay } from '@chatora/core'
import { Effect, Either, Option } from 'effect'
import { type ConcealRange, computeConcealRanges } from './decorations'
import { textToLines } from './lines'
import { computeInternalLinks, titleKey } from './links'
import { computeQuoteRanges, type QuoteRange } from './quote'
import { ReadState } from './readState'
import { type BasePageState, SessionState } from './state'
import { computeTokens, type RawToken } from './tokens'
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
 * Cosense has no unread flag of its own: its web grid computes `updated > accessed`, and so
 * does this. A page never visited has `accessed` 0, so everything starts unread — same as the
 * web UI. `localReadAt` covers the window before the server's own `accessed` catches up, and
 * the case where it never does.
 */
const withUnread = (page: PageSummary, localReadAt: number): ListedPage => ({
  ...page,
  unread: page.updated > Math.max(page.accessed, localReadAt),
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
  SessionState | HttpClient | ReadState
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
      const readState = yield* ReadState
      const listed = yield* Effect.forEach(result.pages, (page) =>
        Effect.map(readState.readAt(params.project, page.id), (at) => withUnread(page, at)),
      )
      // Unread has no server-side filter, so it thins a batch client-side and
      // the caller pages on `scanned` rather than on how many pages it got.
      const pages = params.unreadOnly ? listed.filter((p) => p.unread) : listed
      return { ok: true as const, count: result.count, pages, scanned: listed.length }
    }),
  )

/**
 * A page's own numbers, for the status line and the info panel. All times are Unix
 * seconds; a page that does not exist yet has none of this.
 */
export interface PageMeta {
  readonly created: number
  readonly updated: number
  readonly accessed: number
  readonly views: number
  readonly linked: number
  readonly linesCount: number
  readonly charsCount: number
  /** Sort weight for pinned pages; 0 means not pinned. */
  readonly pin: number
  readonly pageRank: number
  readonly snapshotCount: number
  readonly createdBy?: PageAuthor
  readonly updatedBy?: PageAuthor
  /** Everyone else who has edited the page — Cosense's 共同編集者. Absent when nobody has. */
  readonly collaborators?: readonly PageAuthor[]
}

/**
 * Someone a page can be attributed to. The page body names them by id alone, so `name` and
 * `displayName` are empty when the project roster could not be read — `name` is also what
 * the `.icon` notation is keyed by, which is how the client draws their picture.
 */
export interface PageAuthor {
  readonly id: string
  readonly name: string
  readonly displayName: string
}

/**
 * `toPageMeta` plus the two authors, resolved through the project's cached roster. The
 * roster is one request per project per ten minutes and never fails the caller, so an
 * unreadable one costs the names and nothing else.
 */
const toPageMetaWithAuthors = (
  project: string,
  page: PageDetail,
): Effect.Effect<PageMeta, never, SessionState | HttpClient> =>
  Effect.gen(function* () {
    const meta = toPageMeta(page)
    const named = [page.user?.id, page.lastUpdateUser?.id, ...(page.users ?? []).map((u) => u.id)]
    if (named.every((id) => id === undefined || id === '')) return meta
    const session = yield* SessionState
    const { users } = yield* session.getProjectUsers(project)
    const author = (id: string | undefined): PageAuthor | undefined => {
      if (id === undefined || id === '') return undefined
      const found = users.find((user) => user.id === id)
      return { id, name: found?.name ?? '', displayName: found?.displayName ?? '' }
    }
    const createdBy = author(page.user?.id)
    const updatedBy = author(page.lastUpdateUser?.id)
    // `users` is everyone who has touched the page, the two named above included. Only the
    // rest are collaborators — repeating the author under a second heading says nothing.
    const shown = new Set([createdBy?.id, updatedBy?.id])
    const collaborators = (page.users ?? [])
      .filter((user) => user.id !== '' && !shown.has(user.id))
      .map((user) => author(user.id))
      .filter((entry): entry is PageAuthor => entry !== undefined)
    return {
      ...meta,
      ...(createdBy ? { createdBy } : {}),
      ...(updatedBy ? { updatedBy } : {}),
      ...(collaborators.length > 0 ? { collaborators } : {}),
    }
  })

const toPageMeta = (page: PageDetail): PageMeta => ({
  created: page.created,
  updated: page.updated,
  accessed: page.accessed,
  views: page.views,
  linked: page.linked,
  linesCount: page.linesCount,
  charsCount: page.charsCount,
  pin: page.pin,
  pageRank: page.pageRank,
  snapshotCount: page.snapshotCount,
})

export interface OpenPageResult {
  readonly ok: true
  readonly uri: string
  readonly text: string
  readonly exists: boolean
  readonly pageId?: string
  readonly commitId?: string
  readonly meta?: PageMeta
}

export const openPage = (params: {
  readonly project: string
  readonly title: string
}): Effect.Effect<OpenPageResult | ErrEnvelope, never, SessionState | HttpClient | ReadState> =>
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
        // Opening a page is what marks it read. Recorded locally straight away
        // so the mark clears even if the endpoint rejects this credential, and
        // reported to Cosense in the background so other clients see it too.
        yield* (yield* ReadState).markRead(params.project, page.id)
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
          meta: yield* toPageMetaWithAuthors(params.project, page),
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
// syncPage
// ---------------------------------------------------------------------------

export interface SyncPageResult {
  readonly ok: true
  /** False when the buffer already holds the merged text; the client then does nothing. */
  readonly changed: boolean
  readonly text: string
  readonly conflicts: readonly MergeConflict[]
  readonly meta?: PageMeta
}

/**
 * Bring a buffer up to date with the server without discarding what is in it.
 *
 * Unlike `openPage`, which is a load and therefore an overwrite, this merges: the buffer's
 * unsaved edits are replayed onto the server's current lines, and lines the two disagree
 * about are returned as conflicts with the local text left in place. `docText` is the
 * synced document, looked up at the LSP edge the same way `savePage` does it.
 *
 * The refetched lines become the new base, so the next save diffs against what the server
 * actually holds; the merged text is exactly the edit that turns that into the buffer.
 */
export const syncPage = (
  uri: string,
  docText: string | undefined,
): Effect.Effect<SyncPageResult | ErrEnvelope, never, SessionState | HttpClient> =>
  handle(
    Effect.gen(function* () {
      if (docText === undefined) return err('error', 'document not synced')
      const session = yield* SessionState
      const baseOpt = yield* session.getPage(uri)
      if (Option.isNone(baseOpt)) return err('error', 'page state not found; reopen the page')
      const base = baseOpt.value

      const apiOpt = yield* session.getApi()
      if (Option.isNone(apiOpt)) return noCredential()
      const pageOpt = yield* apiOpt.value.getPage(base.project, base.title)
      // Compared line-wise, not as raw text: the document nvim syncs carries a trailing
      // newline that a joined line list never has, so comparing the two strings directly
      // would report every poll as a change and rewrite the buffer under the cursor.
      const ours = textToLines(docText)
      const before = ours.join('\n')
      if (Option.isNone(pageOpt)) {
        // The page is gone (or never existed). There is nothing to merge onto and nothing
        // to take, so the buffer stands as the only copy of its own text.
        return { ok: true as const, changed: false, text: before, conflicts: [] }
      }
      const page = pageOpt.value

      const { merged, conflicts } = mergeThreeWay(base.baseLines, ours, page.lines)
      yield* session.setPage(uri, {
        project: base.project,
        title: base.title,
        pageId: page.id,
        commitId: page.commitId,
        baseLines: page.lines,
        exists: true,
      })

      const text = merged.join('\n')
      return {
        ok: true as const,
        changed: text !== before,
        text,
        conflicts,
        meta: yield* toPageMetaWithAuthors(base.project, page),
      }
    }),
  )

export interface PreviewPageResult {
  readonly ok: true
  readonly text: string
  /** Same shape textDocument/semanticTokens carries, minus the LSP delta encoding. */
  readonly tokens: readonly RawToken[]
  readonly conceal: readonly ConcealRange[]
  readonly quotes: readonly QuoteRange[]
  readonly meta?: PageMeta
}

/**
 * A page's text, plus everything needed to draw it the way a real page buffer is drawn.
 *
 * Unlike `openPage` this records nothing: no read mark, no `accessed` report, no session
 * entry — scrolling a picker past a page is not reading it, and a preview buffer must
 * never be mistaken for one that can be saved.
 *
 * `text` is empty and the decorations are empty for a page that does not exist.
 */
export const previewPage = (params: {
  readonly project: string
  readonly title: string
}): Effect.Effect<PreviewPageResult | ErrEnvelope, never, SessionState | HttpClient> =>
  handle(
    Effect.gen(function* () {
      const session = yield* SessionState
      const apiOpt = yield* session.getApi()
      if (Option.isNone(apiOpt)) return noCredential()
      const pageOpt = yield* apiOpt.value.getPage(params.project, params.title)
      if (Option.isNone(pageOpt)) {
        return { ok: true as const, text: '', tokens: [], conceal: [], quotes: [] }
      }
      const page = pageOpt.value
      const text = page.lines.map((l) => l.text).join('\n')
      return {
        ok: true as const,
        text,
        tokens: computeTokens(text),
        conceal: computeConcealRanges(text),
        quotes: computeQuoteRanges(text),
        meta: toPageMeta(page),
      }
    }),
  )

// ---------------------------------------------------------------------------
// deletePage
// ---------------------------------------------------------------------------

export interface DeletePageResult {
  readonly ok: true
  readonly title: string
}

/**
 * Delete the page a buffer holds, through the same two-step edit endpoint a save uses: the
 * whole-page sentinel `changes: [{ deleted: true }]` instead of line ops.
 *
 * The preview is only submitted once the server has echoed `pageDelete`, which is the
 * check cosense-cli's own previewDelete refuses to skip — a previewId built from something
 * the server read differently would commit whatever it did read, and this is the one
 * operation with nothing to undo it.
 */
export const deletePage = (
  uri: string,
): Effect.Effect<DeletePageResult | ErrEnvelope, never, SessionState | HttpClient> =>
  handle(
    Effect.gen(function* () {
      const session = yield* SessionState
      const baseOpt = yield* session.getPage(uri)
      if (Option.isNone(baseOpt)) return err('error', 'page state not found; reopen the page')
      const base = baseOpt.value
      if (base.pageId === undefined || !base.exists) {
        return err('error', 'このページはまだ Cosense に存在しません')
      }

      const apiOpt = yield* session.getApi()
      if (Option.isNone(apiOpt)) return noCredential()
      const api = apiOpt.value

      const preview = yield* api.previewEdit(base.project, {
        pageId: base.pageId,
        changes: [{ deleted: true }],
      })
      if (preview.pageDelete !== true) {
        return err('error', 'サーバーが削除として受理しませんでした（中止しました）')
      }
      const submit = yield* api.submitEdit(base.project, preview.previewId)

      yield* session.deletePage(uri)
      // The page is gone from the project, so the title index that still lists it would
      // keep answering link questions with it.
      yield* session.invalidateTitles(base.project)
      return { ok: true as const, title: submit.pageDeleted?.title ?? base.title }
    }),
  )

// ---------------------------------------------------------------------------
// emptyLinks
// ---------------------------------------------------------------------------

export interface EmptyLinksResult {
  readonly ok: true
  readonly links: readonly { line: number; startChar: number; endChar: number }[]
}

/**
 * The links on a page that point at nothing — Cosense's red links.
 *
 * Answered from the project's title index, the same cached list the link completion reads,
 * so this costs one request a minute however often a page is edited — and lags by up to
 * that minute. Being late in this direction is the harmless one: a link wrongly shown as
 * empty corrects itself, where the alternative is a request per link. An index that cannot
 * be read at all yields nothing rather than marking every link on the page.
 */
export const emptyLinks = (
  uri: string,
  docText: string | undefined,
): Effect.Effect<EmptyLinksResult | ErrEnvelope, never, SessionState | HttpClient> =>
  handle(
    Effect.gen(function* () {
      if (docText === undefined) return err('error', 'document not synced')
      const session = yield* SessionState
      const baseOpt = yield* session.getPage(uri)
      if (Option.isNone(baseOpt)) return { ok: true as const, links: [] }
      const base = baseOpt.value

      const links = computeInternalLinks(docText)
      if (links.length === 0) return { ok: true as const, links: [] }

      const titles = yield* session
        .getTitles(base.project)
        .pipe(Effect.orElseSucceed(() => [] as readonly TitleEntry[]))
      if (titles.length === 0) return { ok: true as const, links: [] }
      const known = new Set(titles.map((entry) => titleKey(entry.title)))
      // The page being edited is not in the index until it is saved, and a page linking to
      // itself is not a red link.
      known.add(titleKey(base.title))

      return {
        ok: true as const,
        links: links
          .filter((link) => !known.has(titleKey(link.title)))
          .map(({ line, startChar, endChar }) => ({ line, startChar, endChar })),
      }
    }),
  )

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

/** A save the client must resolve by hand; `text` is the merge, with the local side kept. */
export interface SaveConflictResult {
  readonly ok: false
  readonly code: 'conflict'
  readonly message: string
  readonly text: string
  readonly conflicts: readonly MergeConflict[]
}

const isNotFastForward = (error: unknown): boolean =>
  typeof error === 'object' &&
  error !== null &&
  (error as { _tag?: string })._tag === 'CosenseApiError' &&
  (error as { code?: string }).code === 'NotFastForward'

/**
 * `docText` is the synced document text (or `undefined` when the uri has no open document) —
 * looked up from `TextDocuments` at the LSP edge in main.ts, since that lookup is plain
 * connection state, not something this Effect program needs to depend on.
 *
 * Cosense has no client-supplied version token: `page-edit-for-ai/preview` takes only
 * `{pageId, changes}`, and the server compares against the state the preview captured. So a
 * page that moved between this session's last read and the preview is caught at submit, as
 * `NotFastForward`, and answered here the way the endpoint's own documentation prescribes —
 * refetch, rebuild the ops, preview again. The rebuild is a three-way merge rather than a
 * blind rebase, so a save only fails when the two sides really did touch the same line.
 */
export const savePage = (
  uri: string,
  docText: string | undefined,
): Effect.Effect<
  SavePageResult | SaveConflictResult | ErrEnvelope,
  never,
  SessionState | HttpClient
> =>
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

      const userId = yield* session.verifiedUserId()
      const push = (baseLines: readonly PageDetailLine[], lines: readonly string[]) =>
        Effect.gen(function* () {
          const changes = computeChanges(baseLines, lines, () => createNewLineId(userId))
          if (changes.length === 0) return Option.none<SubmitResponse>()
          const preview = yield* api.previewEdit(
            base.project,
            base.pageId !== undefined ? { pageId: base.pageId, changes } : { changes },
          )
          return Option.some(yield* api.submitEdit(base.project, preview.previewId))
        })

      let nextLines: readonly string[] = textToLines(docText)
      let attempt = yield* Effect.either(push(base.baseLines, nextLines))
      // A merged save wrote something the buffer does not hold, so its text has to travel
      // back whatever the refetch says; without it the buffer would keep the pre-merge
      // lines and the next save would diff them against the merged base and undo the merge.
      let merged = false

      if (Either.isLeft(attempt)) {
        if (!isNotFastForward(attempt.left)) return yield* Effect.fail(attempt.left)
        // The page moved under us. Merge onto what it holds now; only a line both sides
        // touched can still stop the save, and the local text is what survives it.
        const latestOpt = yield* api.getPage(base.project, base.title)
        if (Option.isNone(latestOpt)) return err('error', 'page no longer exists')
        const latest = latestOpt.value
        const { merged: mergedLines, conflicts } = mergeThreeWay(
          base.baseLines,
          nextLines,
          latest.lines,
        )
        yield* session.setPage(uri, {
          project: base.project,
          title: base.title,
          pageId: latest.id,
          commitId: latest.commitId,
          baseLines: latest.lines,
          exists: true,
        })
        if (conflicts.length > 0) {
          return {
            ok: false as const,
            code: 'conflict' as const,
            message: 'リモートと同じ行を編集しています',
            text: mergedLines.join('\n'),
            conflicts,
          }
        }
        nextLines = mergedLines
        merged = true
        attempt = yield* Effect.either(push(latest.lines, mergedLines))
        if (Either.isLeft(attempt)) return yield* Effect.fail(attempt.left)
      }

      const submitted = attempt.right
      if (Option.isNone(submitted)) {
        return { ok: true as const, commitId: base.commitId ?? '', noop: true as const }
      }
      const submit = submitted.value

      const finalTitle = submit.page?.title ?? submit.titleChanged?.to ?? base.title
      // refetched should be non-null right after a successful submit; falling back to what
      // we just sent keeps savePage well-defined even if the server races us on this read.
      const refetchedOpt = yield* api.getPage(base.project, finalTitle)
      const submittedText = nextLines.join('\n')
      const responseText = Option.match(refetchedOpt, {
        onNone: () => undefined,
        onSome: (refetched) => {
          const text = refetched.lines.map((l) => l.text).join('\n')
          return merged || text !== submittedText ? text : undefined
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
      // A page saved for the first time is not in the cached title index, so every link
      // pointing at it would keep reading as empty until that cache aged out on its own.
      if (!base.exists || newUri !== uri) yield* session.invalidateTitles(base.project)

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
