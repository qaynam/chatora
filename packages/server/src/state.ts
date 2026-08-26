import type {
  CosenseApiError,
  CosenseApiShape,
  Credential,
  HttpClient,
  KeychainError,
  Me,
  PageDetailLine,
  ProjectUsers,
  TitleEntry,
  VectorResultPage,
} from '@chatora/core'
import { CredentialStore, makeCosenseApi } from '@chatora/core'
import { Clock, Context, Effect, Layer, Option, Ref, SynchronizedRef } from 'effect'
import { loadTitles, saveTitles } from './titleStore'

export interface BasePageState {
  readonly project: string
  readonly title: string
  readonly pageId?: string
  readonly commitId?: string
  readonly baseLines: readonly PageDetailLine[]
  readonly exists: boolean
}

// Long enough that starting Neovim does not re-download a whole project's titles, and
// tolerable because the two things that change it locally — creating a page, deleting one —
// update the list in place rather than waiting for it to expire.
const TITLES_CACHE_TTL_MS = 300_000
// A project's roster changes far more slowly than its pages, and it is only ever read to
// put a name on an author, so a stale entry costs nothing worse than a stale display name.
const USERS_CACHE_TTL_MS = 600_000
const VECTOR_CACHE_TTL_MS = 30_000
const VECTOR_CACHE_MAX = 200

interface UsersCacheEntry {
  readonly fetchedAt: number
  readonly value: ProjectUsers
}

interface TitlesCacheEntry {
  readonly fetchedAt: number
  readonly titles: readonly TitleEntry[]
}

interface VectorCacheEntry {
  readonly at: number
  readonly pages: readonly VectorResultPage[]
}

// Tri-state memo: 'unresolved' until the first getCredential() call, then pinned to
// whatever CredentialStore.resolve found — including "found nothing" — for the rest of the
// session. CredentialStore.resolve(origin) takes no project (one credential per origin now
// that service accounts have no resolver), so unlike the old per-project ServerState there
// is exactly one slot to cache, not a Map.
type CredentialCache =
  | { readonly status: 'unresolved' }
  | { readonly status: 'resolved'; readonly credential: Option.Option<Credential> }

const UNRESOLVED_CREDENTIAL: CredentialCache = { status: 'unresolved' }

type VerifiedCache =
  | { readonly status: 'unattempted' }
  | { readonly status: 'ok'; readonly user: Me }
  | { readonly status: 'failed' }

const UNATTEMPTED_VERIFIED: VerifiedCache = { status: 'unattempted' }

export interface SessionStateShape {
  readonly origin: string
  /** Resolution order: env, then Keychain (@chatora/core CredentialStore) — cached for the session. */
  readonly getCredential: () => Effect.Effect<Option.Option<Credential>>
  /** `getCredential` plus building a `CosenseApi` bound to it; `Option.none` when unauthenticated. */
  readonly getApi: () => Effect.Effect<Option.Option<CosenseApiShape>>
  /** Uncached: builds a CosenseApi for an explicit credential (login verifies before storing/caching it). */
  readonly apiFor: (credential: Credential) => CosenseApiShape
  /** Login/logout invalidate every cache — a fresh credential may resolve, or verify, differently. */
  readonly invalidateCredentials: () => Effect.Effect<void>
  /** Verifies /api/users/me at most once per session; both success and failure stay cached until invalidated. */
  readonly ensureVerified: () => Effect.Effect<Option.Option<Me>, never, HttpClient>
  readonly setVerifiedUser: (user: Me) => Effect.Effect<void>
  /** The verified user's id, or '' if this session hasn't verified yet (savePage's line-id generation). */
  readonly verifiedUserId: () => Effect.Effect<string>
  readonly storeCredential: (pat: string) => Effect.Effect<void, KeychainError>
  readonly removeCredential: () => Effect.Effect<void, KeychainError>
  /**
   * Vector (semantic) title search, cached briefly per (project, query) — completion
   * re-queries on every keystroke, and backspacing replays recent queries. Fails on API
   * error (490 = disabled already folds into `{pages:[]}` inside @chatora/core); callers
   * fall back to the local title index on failure.
   */
  readonly searchVectorCached: (
    project: string,
    query: string,
  ) => Effect.Effect<readonly VectorResultPage[], CosenseApiError, HttpClient>
  /** `project`'s id and everyone who can be named as an author in it. Empty when unreadable. */
  readonly getProjectUsers: (project: string) => Effect.Effect<ProjectUsers, never, HttpClient>
  /**
   * Record that `title` now exists in `project`, or no longer does. Keeping the index
   * current in place is what lets it be cached for minutes: a page saved for the first time
   * stops reading as an empty link straight away, without re-downloading the whole list.
   */
  readonly noteTitle: (
    project: string,
    title: string,
    exists: boolean,
  ) => Effect.Effect<void, never, HttpClient>
  readonly getTitles: (
    project: string,
  ) => Effect.Effect<readonly TitleEntry[], CosenseApiError, HttpClient>
  readonly getPage: (uri: string) => Effect.Effect<Option.Option<BasePageState>>
  readonly setPage: (uri: string, state: BasePageState) => Effect.Effect<void>
  readonly deletePage: (uri: string) => Effect.Effect<void>
}

/**
 * Session state for one LSP connection: origin, cached credential, the once-per-session
 * verified user, the title cache and vector-search cache (both used by completion), and
 * open pages' base diff state keyed by cosense:// URI (see openPage/savePage in pages.ts).
 */
export class SessionState extends Context.Tag('@chatora/server/SessionState')<
  SessionState,
  SessionStateShape
>() {}

/** Builds the `SessionState` service for one connection; `origin` is fixed at construction time. */
export const makeSessionStateLayer = (
  origin: string,
): Layer.Layer<SessionState, never, CredentialStore> =>
  Layer.effect(
    SessionState,
    Effect.gen(function* () {
      const store = yield* CredentialStore
      const credentialRef = yield* SynchronizedRef.make<CredentialCache>(UNRESOLVED_CREDENTIAL)
      const verifiedRef = yield* SynchronizedRef.make<VerifiedCache>(UNATTEMPTED_VERIFIED)
      const titlesCacheRef = yield* Ref.make<ReadonlyMap<string, TitlesCacheEntry>>(new Map())
      const usersCacheRef = yield* Ref.make<ReadonlyMap<string, UsersCacheEntry>>(new Map())
      const vectorCacheRef = yield* Ref.make<ReadonlyMap<string, VectorCacheEntry>>(new Map())
      const pagesRef = yield* Ref.make<ReadonlyMap<string, BasePageState>>(new Map())

      // SynchronizedRef serializes concurrent callers onto one CredentialStore.resolve call
      // instead of racing several in-flight resolutions to the same cache slot.
      const getCredential: SessionStateShape['getCredential'] = () =>
        SynchronizedRef.modifyEffect(credentialRef, (cache) =>
          cache.status === 'resolved'
            ? Effect.succeed([cache.credential, cache] as const)
            : Effect.map(
                store.resolve(origin),
                (credential): readonly [Option.Option<Credential>, CredentialCache] => [
                  credential,
                  { status: 'resolved', credential },
                ],
              ),
        )

      const getApi: SessionStateShape['getApi'] = () =>
        Effect.map(
          getCredential(),
          Option.map((credential) => makeCosenseApi({ origin, credential })),
        )

      const apiFor: SessionStateShape['apiFor'] = (credential) =>
        makeCosenseApi({ origin, credential })

      const invalidateCredentials: SessionStateShape['invalidateCredentials'] = () =>
        Effect.all(
          [
            SynchronizedRef.set(credentialRef, UNRESOLVED_CREDENTIAL),
            SynchronizedRef.set(verifiedRef, UNATTEMPTED_VERIFIED),
            Ref.set(titlesCacheRef, new Map()),
            Ref.set(vectorCacheRef, new Map()),
          ],
          { discard: true },
        )

      const ensureVerified: SessionStateShape['ensureVerified'] = () =>
        SynchronizedRef.modifyEffect(verifiedRef, (cache) => {
          if (cache.status !== 'unattempted') {
            const user = cache.status === 'ok' ? Option.some(cache.user) : Option.none<Me>()
            return Effect.succeed([user, cache] as const)
          }
          return Effect.flatMap(getApi(), (apiOpt) =>
            Option.match(apiOpt, {
              // No credential at all: leave the cache 'unattempted' so a later login can
              // still trigger a real verification instead of being permanently 'failed'.
              onNone: () => Effect.succeed([Option.none<Me>(), cache] as const),
              onSome: (api) =>
                api.me().pipe(
                  Effect.map((user): readonly [Option.Option<Me>, VerifiedCache] => [
                    Option.some(user),
                    { status: 'ok', user },
                  ]),
                  Effect.catchAll(() =>
                    Effect.succeed([
                      Option.none<Me>(),
                      { status: 'failed' } as VerifiedCache,
                    ] as const),
                  ),
                ),
            }),
          )
        })

      const setVerifiedUser: SessionStateShape['setVerifiedUser'] = (user) =>
        SynchronizedRef.set(verifiedRef, { status: 'ok', user })

      const verifiedUserId: SessionStateShape['verifiedUserId'] = () =>
        Effect.map(SynchronizedRef.get(verifiedRef), (cache) =>
          cache.status === 'ok' ? cache.user.id : '',
        )

      const storeCredential: SessionStateShape['storeCredential'] = (pat) =>
        store.store(origin, pat)
      const removeCredential: SessionStateShape['removeCredential'] = () => store.remove(origin)

      const searchVectorCached: SessionStateShape['searchVectorCached'] = (project, query) =>
        Effect.gen(function* () {
          const key = `${project}\0${query}`
          const now = yield* Clock.currentTimeMillis
          const cache = yield* Ref.get(vectorCacheRef)
          const cached = cache.get(key)
          if (cached && now - cached.at < VECTOR_CACHE_TTL_MS) return cached.pages

          const apiOpt = yield* getApi()
          if (Option.isNone(apiOpt)) return []
          const result = yield* apiOpt.value.searchVector(project, query)

          yield* Ref.update(vectorCacheRef, (map) => {
            const next = new Map(map)
            if (next.size >= VECTOR_CACHE_MAX) {
              const oldestKey = next.keys().next().value
              if (oldestKey !== undefined) next.delete(oldestKey)
            }
            next.set(key, { at: now, pages: result.pages })
            return next
          })
          return result.pages
        })

      const getProjectUsers: SessionStateShape['getProjectUsers'] = (project) =>
        Effect.gen(function* () {
          const now = yield* Clock.currentTimeMillis
          const cache = yield* Ref.get(usersCacheRef)
          const cached = cache.get(project)
          if (cached && now - cached.fetchedAt < USERS_CACHE_TTL_MS) return cached.value

          const empty: ProjectUsers = { projectId: '', users: [] }
          const apiOpt = yield* getApi()
          if (Option.isNone(apiOpt)) return empty
          // A roster that cannot be read is not a reason to fail whatever wanted it: the
          // caller falls back to showing the author's id, or nothing at all.
          const value = yield* apiOpt.value
            .projectUsers(project)
            .pipe(Effect.orElseSucceed(() => empty))
          yield* Ref.update(usersCacheRef, (map) =>
            new Map(map).set(project, { fetchedAt: now, value }),
          )
          return value
        })

      const noteTitle: SessionStateShape['noteTitle'] = (project, title, exists) =>
        Effect.gen(function* () {
          const cache = yield* Ref.get(titlesCacheRef)
          const cached = cache.get(project)
          if (cached === undefined) return
          const without = cached.titles.filter((entry) => entry.title !== title)
          if (exists && without.length === cached.titles.length) {
            // The id is the index's own; a page this session just created has one, but the
            // index is only ever read for its titles, so a placeholder is enough.
            without.push({ id: '', title, titleLc: '', updated: 0, image: null })
          } else if (exists) {
            return
          }
          const entry = { fetchedAt: cached.fetchedAt, titles: without }
          yield* Ref.update(titlesCacheRef, (map) => new Map(map).set(project, entry))
          yield* saveTitles(project, entry)
        })

      const getTitles: SessionStateShape['getTitles'] = (project) =>
        Effect.gen(function* () {
          const now = yield* Clock.currentTimeMillis
          const fresh = (at: number) => now - at < TITLES_CACHE_TTL_MS
          const cache = yield* Ref.get(titlesCacheRef)
          const cached = cache.get(project)
          if (cached && fresh(cached.fetchedAt)) return cached.titles

          // Disk before network: a project's titles are hundreds of kilobytes, and paying
          // for them again at every startup delays the first page's links for no reason.
          if (cached === undefined) {
            const stored = yield* loadTitles(project)
            if (stored && fresh(stored.fetchedAt)) {
              yield* Ref.update(titlesCacheRef, (map) => new Map(map).set(project, stored))
              return stored.titles
            }
          }

          const apiOpt = yield* getApi()
          if (Option.isNone(apiOpt)) return []
          const titles = yield* apiOpt.value.searchTitles(project)
          const entry = { fetchedAt: now, titles }
          yield* Ref.update(titlesCacheRef, (map) => new Map(map).set(project, entry))
          yield* saveTitles(project, entry)
          return titles
        })

      const getPage: SessionStateShape['getPage'] = (uri) =>
        Effect.map(Ref.get(pagesRef), (map) => Option.fromNullable(map.get(uri)))

      const setPage: SessionStateShape['setPage'] = (uri, pageState) =>
        Ref.update(pagesRef, (map) => new Map(map).set(uri, pageState))

      const deletePage: SessionStateShape['deletePage'] = (uri) =>
        Ref.update(pagesRef, (map) => {
          if (!map.has(uri)) return map
          const next = new Map(map)
          next.delete(uri)
          return next
        })

      return SessionState.of({
        origin,
        getCredential,
        getApi,
        apiFor,
        invalidateCredentials,
        ensureVerified,
        setVerifiedUser,
        verifiedUserId,
        storeCredential,
        removeCredential,
        searchVectorCached,
        getProjectUsers,
        noteTitle,
        getTitles,
        getPage,
        setPage,
        deletePage,
      })
    }),
  )
