import { Effect, Option, Schema } from 'effect'
import type { Credential } from './credentials'
import { CosenseApiError } from './errors'
import { HttpClient } from './httpClient'
import {
  Links1HopResponseSchema,
  Links2HopResponseSchema,
  ListPagesResponseSchema,
  MeSchema,
  PageV2ResponseSchema,
  PreviewResponseSchema,
  ProjectDetailSchema,
  ProjectsResponseSchema,
  ProjectUsersResponseSchema,
  ReplaceLinksResponseSchema,
  SearchFullTextResponseSchema,
  SearchVectorResponseSchema,
  SubmitResponseSchema,
  TitleEntryArraySchema,
  TitleEntryEnvelopeSchema,
} from './schemas'
import type {
  Me,
  PageDetail,
  PageSummary,
  PreviewEditBody,
  PreviewResponse,
  ProjectDetail,
  ProjectSummary,
  ProjectUsers,
  RelatedPages,
  SearchResult,
  SubmitResponse,
  TitleEntry,
  UserRef,
  VectorResult,
} from './types'

// Keep Unicode and spaces readable in page URLs while escaping characters that would change
// route matching. This is separate from the `cosense://` URI encoding.
const encodeTitleForUrl = (title: string): string =>
  title
    .replace(/%/g, '%25')
    .replace(/\//g, '%2F')
    .replace(/\?/g, '%3F')
    .replace(/#/g, '%23')
    .replace(/ /g, '_')

const REDIRECT_STATUS_MIN = 300
const REDIRECT_STATUS_MAX = 400
const VECTOR_SEARCH_DISABLED_STATUS = 490

// The picker renders the response directly, so this cap bounds a broad query.
const FULL_TEXT_SEARCH_LIMIT = 100
const NOT_FOUND_STATUS = 404

const parseErrorCode = (bodyText: string): string | undefined => {
  try {
    const parsed: unknown = JSON.parse(bodyText)
    if (typeof parsed === 'object' && parsed !== null && 'error' in parsed) {
      const value = (parsed as { error?: unknown }).error
      if (typeof value === 'string') return value
    }
  } catch {
    // body wasn't JSON (or wasn't {"error": "..."}); no code to extract
  }
  return undefined
}

type Method = 'GET' | 'POST'

export interface CosenseApiConfig {
  readonly origin: string
  readonly credential: Credential
}

// Build the credential header required by the selected credential type.
const buildHeaders = (credential: Credential, hasBody: boolean): Record<string, string> => {
  const headers: Record<string, string> =
    credential.type === 'serviceAccount'
      ? { 'x-service-account-access-key': credential.value }
      : { 'x-personal-access-token': credential.value }
  if (hasBody) headers['Content-Type'] = 'application/json'
  return headers
}

interface RawResponse {
  readonly status: number
  readonly body: unknown
  /** Response headers, for the few endpoints that page through one. */
  readonly headers: Headers
}

// Handle redirects manually so credential headers never travel to another origin. Following
// same-origin redirects keeps links written before a page rename working.
const MAX_REDIRECTS = 3

/**
 * `location` as a path to re-request, or undefined when it leaves `origin`.
 *
 * Redirects are handled here rather than by fetch because these requests carry credentials:
 * `redirect: 'manual'` is what stops them being replayed at whatever host a response names.
 * Staying on the origin the credential belongs to is the whole condition for following one.
 */
const sameOriginPath = (origin: string, location: string): string | undefined => {
  try {
    const resolved = new URL(location, origin)
    return resolved.origin === new URL(origin).origin
      ? `${resolved.pathname}${resolved.search}`
      : undefined
  } catch {
    return undefined
  }
}

const requestRaw = (
  origin: string,
  credential: Credential,
  path: string,
  init?: { method?: Method; body?: unknown },
  hop = 0,
): Effect.Effect<Response, CosenseApiError, HttpClient> =>
  Effect.gen(function* () {
    const client = yield* HttpClient
    const hasBody = init?.body !== undefined
    const res = yield* client
      .fetch(`${origin}${path}`, {
        method: init?.method ?? 'GET',
        headers: buildHeaders(credential, hasBody),
        body: hasBody ? JSON.stringify(init?.body) : undefined,
        redirect: 'manual',
      })
      .pipe(
        Effect.mapError(
          (httpClientError) =>
            new CosenseApiError({
              status: 0,
              message: `Request failed: ${String(httpClientError.cause)}`,
            }),
        ),
      )

    if (res.status >= REDIRECT_STATUS_MIN && res.status < REDIRECT_STATUS_MAX) {
      const location = res.headers.get('location')
      const next = location === null ? undefined : sameOriginPath(origin, location)
      if (next !== undefined && hop < MAX_REDIRECTS) {
        return yield* requestRaw(origin, credential, next, init, hop + 1)
      }
      return yield* Effect.fail(
        new CosenseApiError({
          status: res.status,
          message: `Unexpected redirect (HTTP ${res.status})`,
        }),
      )
    }
    if (!res.ok) {
      const bodyText = yield* Effect.tryPromise(() => res.text()).pipe(
        Effect.orElseSucceed(() => ''),
      )
      const code = parseErrorCode(bodyText)
      return yield* Effect.fail(
        new CosenseApiError({
          status: res.status,
          message: `HTTP ${res.status} ${res.statusText}`.trim(),
          ...(code !== undefined ? { code } : {}),
        }),
      )
    }
    return res
  })

const requestJson = (
  origin: string,
  credential: Credential,
  path: string,
  init?: { method?: Method; body?: unknown },
): Effect.Effect<RawResponse, CosenseApiError, HttpClient> =>
  requestRaw(origin, credential, path, init).pipe(
    Effect.flatMap((res) =>
      Effect.tryPromise({
        try: () => res.json(),
        catch: (cause) =>
          new CosenseApiError({
            status: res.status,
            code: 'DecodeError',
            message: `Response body was not valid JSON: ${String(cause)}`,
          }),
      }).pipe(Effect.map((body) => ({ status: res.status, body, headers: res.headers }))),
    ),
  )

/** For the endpoints that answer with a file rather than JSON. */
const requestText = (
  origin: string,
  credential: Credential,
  path: string,
): Effect.Effect<string, CosenseApiError, HttpClient> =>
  requestRaw(origin, credential, path).pipe(
    Effect.flatMap((res) =>
      Effect.tryPromise({
        try: () => res.text(),
        catch: (cause) =>
          new CosenseApiError({
            status: res.status,
            code: 'DecodeError',
            message: `Response body could not be read: ${String(cause)}`,
          }),
      }),
    ),
  )

const decode = <A, I>(
  schema: Schema.Schema<A, I>,
  response: RawResponse,
): Effect.Effect<A, CosenseApiError> =>
  Schema.decodeUnknown(schema)(response.body).pipe(
    Effect.mapError(
      (parseError) =>
        new CosenseApiError({
          status: response.status,
          code: 'DecodeError',
          message: parseError.message,
        }),
    ),
  )

export interface CosenseApiShape {
  readonly me: () => Effect.Effect<Me, CosenseApiError, HttpClient>
  readonly projects: () => Effect.Effect<readonly ProjectSummary[], CosenseApiError, HttpClient>
  /** Everyone who can be named as a page's author, current members and departed alike. */
  readonly projectUsers: (
    project: string,
  ) => Effect.Effect<ProjectUsers, CosenseApiError, HttpClient>
  /** One project's own settings, including where it wants uploaded images to go. */
  readonly projectDetail: (
    project: string,
  ) => Effect.Effect<ProjectDetail, CosenseApiError, HttpClient>
  readonly listPages: (
    project: string,
    opts?: {
      readonly skip?: number
      readonly limit?: number
      readonly sort?: string
      /** Cosense's saved-filter pair, e.g. `'icon'` / a user name. Both are needed for either to apply. */
      readonly filterType?: string
      readonly filterValue?: string
    },
  ) => Effect.Effect<
    { readonly count: number; readonly pages: readonly PageSummary[] },
    CosenseApiError,
    HttpClient
  >
  /** `Option.none` for both a real HTTP 404 and a `persistent: false` template response — see `PageDetail`'s doc. */
  readonly getPage: (
    project: string,
    title: string,
  ) => Effect.Effect<Option.Option<PageDetail>, CosenseApiError, HttpClient>
  /** Issues links1hop and links2hop concurrently. */
  readonly relatedPages: (
    project: string,
    title: string,
  ) => Effect.Effect<RelatedPages, CosenseApiError, HttpClient>
  /**
   * Cosense's "Export for AI" (Smart Context): the page and everything within `hop` links
   * of it, as one text file. `search` narrows the linked pages the way the related-page
   * box does. The web offers a temporary shared URL for the same text, but the endpoint
   * behind it answers only to a browser session, not to a token.
   */
  readonly exportForAi: (
    project: string,
    title: string,
    hop: 1 | 2,
    search?: string,
  ) => Effect.Effect<string, CosenseApiError, HttpClient>
  readonly searchFullText: (
    project: string,
    query: string,
  ) => Effect.Effect<SearchResult, CosenseApiError, HttpClient>
  /** Unavailable vector search folds into `{ pages: [] }` instead of failing. */
  readonly searchVector: (
    project: string,
    query: string,
  ) => Effect.Effect<VectorResult, CosenseApiError, HttpClient>
  readonly searchTitles: (
    project: string,
  ) => Effect.Effect<readonly TitleEntry[], CosenseApiError, HttpClient>
  readonly previewEdit: (
    project: string,
    body: PreviewEditBody,
  ) => Effect.Effect<PreviewResponse, CosenseApiError, HttpClient>
  readonly submitEdit: (
    project: string,
    previewId: string,
  ) => Effect.Effect<SubmitResponse, CosenseApiError, HttpClient>
  /**
   * Rewrites every `[from]`, `#from` and `[from.icon]` in the project to name `to`; the
   * page itself keeps its title (that is a title-line edit). Matching ignores case and the
   * space/underscore difference, and cross-project `[/p/from]` links are left alone.
   * A 500 means some pages were not rewritten, and the same call can be repeated safely.
   */
  readonly replaceLinks: (
    project: string,
    from: string,
    to: string,
  ) => Effect.Effect<{ readonly message: string }, CosenseApiError, HttpClient>
  /** Records a visit, which is what clears the page's unread state. Never fails: see the implementation. */
  readonly markAccessed: (project: string, pageId: string) => Effect.Effect<void, never, HttpClient>
}

/** Builds a `CosenseApi` bound to one origin + credential. Every operation requires `HttpClient` in scope. */
export const makeCosenseApi = (config: CosenseApiConfig): CosenseApiShape => {
  const { origin, credential } = config
  const request = (path: string, init?: { method?: Method; body?: unknown }) =>
    requestJson(origin, credential, path, init)

  const me: CosenseApiShape['me'] = () =>
    request('/api/users/me').pipe(Effect.flatMap((res) => decode(MeSchema, res)))

  const projects: CosenseApiShape['projects'] = () =>
    request('/api/projects').pipe(
      Effect.flatMap((res) => decode(ProjectsResponseSchema, res)),
      Effect.map((data) => data.projects),
    )

  const projectDetail: CosenseApiShape['projectDetail'] = (project) =>
    request(`/api/projects/${encodeURIComponent(project)}`).pipe(
      Effect.flatMap((res) => decode(ProjectDetailSchema, res)),
    )

  const projectUsers: CosenseApiShape['projectUsers'] = (project) =>
    request(`/api/projects/${encodeURIComponent(project)}/users`).pipe(
      Effect.flatMap((res) => decode(ProjectUsersResponseSchema, res)),
      Effect.map((data) => ({
        projectId: data.projectId,
        users: [
          ...data.users,
          ...data.memberSnapshots.flatMap((snapshot) => (snapshot.data ? [snapshot.data] : [])),
        ],
      })),
    )

  const listPages: CosenseApiShape['listPages'] = (project, opts = {}) => {
    const params = new URLSearchParams()
    if (opts.sort !== undefined) params.set('sort', opts.sort)
    if (opts.limit !== undefined) params.set('limit', String(opts.limit))
    if (opts.skip !== undefined) params.set('skip', String(opts.skip))
    if (opts.filterType !== undefined && opts.filterValue !== undefined) {
      params.set('filterType', opts.filterType)
      params.set('filterValue', opts.filterValue)
    }
    const query = params.toString()
    return request(`/api/pages/${project}/${query ? `?${query}` : ''}`).pipe(
      Effect.flatMap((res) => decode(ListPagesResponseSchema, res)),
    )
  }

  const getPage: CosenseApiShape['getPage'] = (project, title) => {
    // followRename resolves a title the page has since moved away from, which is what a
    // link written before the rename still says.
    const path = `/api/pages/v2/${project}/${encodeTitleForUrl(title)}/?followRename=true`
    return request(path).pipe(
      Effect.flatMap((res) => decode(PageV2ResponseSchema, res)),
      Effect.map(
        (data): Option.Option<PageDetail> =>
          data.persistent === false
            ? Option.none()
            : Option.some({
                id: data.id,
                title: data.title ?? title,
                commitId: data.commitId,
                lines: data.lines,
                created: data.created,
                updated: data.updated,
                accessed: data.accessed,
                views: data.views,
                linked: data.linked,
                linesCount: data.linesCount,
                charsCount: data.charsCount,
                pin: data.pin,
                pageRank: data.pageRank,
                snapshotCount: data.snapshotCount,
                ...(data.user ? { user: data.user } : {}),
                ...(data.users.length > 0 ? { users: data.users } : {}),
                ...(data.lastUpdateUser ? { lastUpdateUser: data.lastUpdateUser } : {}),
              }),
      ),
      Effect.catchAll((err) =>
        err.status === NOT_FOUND_STATUS
          ? Effect.succeed(Option.none<PageDetail>())
          : Effect.fail(err),
      ),
    )
  }

  const relatedPages: CosenseApiShape['relatedPages'] = (project, title) => {
    const base = `/api/pages/v2/${project}/${encodeTitleForUrl(title)}`
    return Effect.all(
      [
        request(`${base}/links1hop`).pipe(
          Effect.flatMap((res) => decode(Links1HopResponseSchema, res)),
        ),
        request(`${base}/links2hop`).pipe(
          Effect.flatMap((res) => decode(Links2HopResponseSchema, res)),
        ),
      ],
      { concurrency: 'unbounded' },
    ).pipe(Effect.map(([hop1, hop2]) => ({ links1hop: hop1.links1hop, links2hop: hop2.links2hop })))
  }

  const exportForAi: CosenseApiShape['exportForAi'] = (project, title, hop, search) => {
    // The title travels as a query parameter, so it takes the ordinary encoding here and
    // not encodeTitleForUrl, which is for the path.
    const query = new URLSearchParams({ title })
    const filter = search?.trim() ?? ''
    if (filter !== '') query.append('search', filter)
    return requestText(
      origin,
      credential,
      `/api/smart-context/export-${hop}hop-links/${encodeURIComponent(project)}.txt?${query.toString()}`,
    )
  }

  const searchFullText: CosenseApiShape['searchFullText'] = (project, query) =>
    request(
      `/api/pages/${project}/search/query?${new URLSearchParams({
        q: query,
        // `field=lines` requests full-text matches, while `pageRank` keeps useful pages near
        // the top of the result.
        skip: '0',
        limit: String(FULL_TEXT_SEARCH_LIMIT),
        sort: 'pageRank',
        field: 'lines',
      })}`,
    ).pipe(Effect.flatMap((res) => decode(SearchFullTextResponseSchema, res)))

  const searchVector: CosenseApiShape['searchVector'] = (project, query) =>
    request(`/api/pages/${project}/search/vector/titles?q=${encodeURIComponent(query)}`).pipe(
      Effect.flatMap((res) => decode(SearchVectorResponseSchema, res)),
      // An unavailable vector index is not a failure for the local completion flow.
      Effect.catchAll((err) =>
        err.status === VECTOR_SEARCH_DISABLED_STATUS
          ? Effect.succeed<VectorResult>({ pages: [] })
          : Effect.fail(err),
      ),
    )

  // `search/titles` answers with at most this many entries and an `x-following-id` naming
  // where the next page starts. A project larger than one page is common enough that
  // stopping at the first would quietly report most of it as pages that do not exist.
  const TITLES_PER_PAGE_CAP = 10_000
  const MAX_TITLE_PAGES = 20

  const titlesPage = (
    project: string,
    followingId: string | undefined,
  ): Effect.Effect<
    { titles: readonly TitleEntry[]; next: string | undefined },
    CosenseApiError,
    HttpClient
  > =>
    request(
      `/api/pages/${project}/search/titles${followingId === undefined ? '' : `?followingId=${followingId}`}`,
    ).pipe(
      Effect.flatMap((res) =>
        (Array.isArray(res.body)
          ? decode(TitleEntryArraySchema, res)
          : decode(TitleEntryEnvelopeSchema, res).pipe(Effect.map((data) => data.pages))
        ).pipe(
          Effect.map((titles) => {
            const header = res.headers.get('x-following-id')
            return { titles, next: header === null || header === '' ? undefined : header }
          }),
        ),
      ),
    )

  const searchTitles: CosenseApiShape['searchTitles'] = (project) =>
    Effect.gen(function* () {
      const all: TitleEntry[] = []
      let following: string | undefined
      // Bounded rather than "until the header is empty": this walks a whole project, and a
      // server that kept naming a next page would otherwise never stop.
      for (let page = 0; page < MAX_TITLE_PAGES; page++) {
        const { titles, next } = yield* titlesPage(project, following)
        all.push(...titles)
        if (next === undefined || titles.length < TITLES_PER_PAGE_CAP) break
        following = next
      }
      return all
    })

  /** Record a page visit in the background; failure does not block the local view. */
  const markAccessed: CosenseApiShape['markAccessed'] = (project, pageId) => {
    const path = `/api/pages/${project}/${encodeURIComponent(pageId)}/accessed`
    return request(path, { method: 'POST', body: {} }).pipe(
      Effect.catchAll(() => request(path)),
      Effect.asVoid,
      Effect.catchAll(() => Effect.void),
    )
  }

  const previewEdit: CosenseApiShape['previewEdit'] = (project, body) =>
    request(`/api/pages/v2/${project}/page-edit-for-ai/preview`, { method: 'POST', body }).pipe(
      Effect.flatMap((res) => decode(PreviewResponseSchema, res)),
    )

  const submitEdit: CosenseApiShape['submitEdit'] = (project, previewId) =>
    request(`/api/pages/v2/${project}/page-edit-for-ai/submit`, {
      method: 'POST',
      body: { previewId },
    }).pipe(Effect.flatMap((res) => decode(SubmitResponseSchema, res)))

  const replaceLinks: CosenseApiShape['replaceLinks'] = (project, from, to) =>
    request(`/api/pages/${project}/replace/links`, {
      method: 'POST',
      body: { from, to },
    }).pipe(Effect.flatMap((res) => decode(ReplaceLinksResponseSchema, res)))

  return {
    me,
    projects,
    projectDetail,
    projectUsers,
    listPages,
    getPage,
    relatedPages,
    exportForAi,
    searchFullText,
    searchVector,
    searchTitles,
    previewEdit,
    submitEdit,
    replaceLinks,
    markAccessed,
  }
}
