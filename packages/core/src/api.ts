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
  ProjectsResponseSchema,
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
  ProjectSummary,
  RelatedPages,
  SearchResult,
  SubmitResponse,
  TitleEntry,
  VectorResult,
} from './types'

// Human-readable-URL title encoder, ported from cosense-cli src/lib/encodeTitle.ts
// (encodeTitleForUrl). Deliberately NOT encodeURIComponent, despite the architecture doc
// naming that function: cosense keeps unicode raw in the URL and maps space -> '_', only
// percent-encoding the characters that would otherwise break route matching (%, /, ?, #).
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

// Headers per cosense-cli src/lib/request.ts buildCredentialHeaders.
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
}

// redirect: 'manual' + treat any 3xx as an error so credential headers never travel to a
// redirect target on a different origin (architecture doc "セキュリティ / 作法"; cosense-cli
// applies the same policy for file downloads in src/lib/request.ts downloadToFile).
const requestJson = (
  origin: string,
  credential: Credential,
  path: string,
  init?: { method?: Method; body?: unknown },
): Effect.Effect<RawResponse, CosenseApiError, HttpClient> =>
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
    const body = yield* Effect.tryPromise({
      try: () => res.json(),
      catch: (cause) =>
        new CosenseApiError({
          status: res.status,
          code: 'DecodeError',
          message: `Response body was not valid JSON: ${String(cause)}`,
        }),
    })
    return { status: res.status, body }
  })

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
  readonly listPages: (
    project: string,
    opts?: { readonly skip?: number; readonly limit?: number; readonly sort?: string },
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
  readonly searchFullText: (
    project: string,
    query: string,
  ) => Effect.Effect<SearchResult, CosenseApiError, HttpClient>
  /** HTTP 490 (vector search disabled for this project) folds into `{ pages: [] }` instead of failing. */
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

  const listPages: CosenseApiShape['listPages'] = (project, opts = {}) => {
    const params = new URLSearchParams()
    if (opts.sort !== undefined) params.set('sort', opts.sort)
    if (opts.limit !== undefined) params.set('limit', String(opts.limit))
    if (opts.skip !== undefined) params.set('skip', String(opts.skip))
    const query = params.toString()
    return request(`/api/pages/${project}/${query ? `?${query}` : ''}`).pipe(
      Effect.flatMap((res) => decode(ListPagesResponseSchema, res)),
    )
  }

  const getPage: CosenseApiShape['getPage'] = (project, title) => {
    const path = `/api/pages/v2/${project}/${encodeTitleForUrl(title)}`
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

  const searchFullText: CosenseApiShape['searchFullText'] = (project, query) =>
    request(`/api/pages/${project}/search/query?q=${encodeURIComponent(query)}`).pipe(
      Effect.flatMap((res) => decode(SearchFullTextResponseSchema, res)),
    )

  const searchVector: CosenseApiShape['searchVector'] = (project, query) =>
    request(`/api/pages/${project}/search/vector/titles?q=${encodeURIComponent(query)}`).pipe(
      Effect.flatMap((res) => decode(SearchVectorResponseSchema, res)),
      // HTTP 490 = vector search disabled for this project (architecture doc).
      Effect.catchAll((err) =>
        err.status === VECTOR_SEARCH_DISABLED_STATUS
          ? Effect.succeed<VectorResult>({ pages: [] })
          : Effect.fail(err),
      ),
    )

  const searchTitles: CosenseApiShape['searchTitles'] = (project) =>
    request(`/api/pages/${project}/search/titles`).pipe(
      Effect.flatMap((res) =>
        Array.isArray(res.body)
          ? decode(TitleEntryArraySchema, res)
          : decode(TitleEntryEnvelopeSchema, res).pipe(Effect.map((data) => data.pages)),
      ),
    )

  const previewEdit: CosenseApiShape['previewEdit'] = (project, body) =>
    request(`/api/pages/v2/${project}/page-edit-for-ai/preview`, { method: 'POST', body }).pipe(
      Effect.flatMap((res) => decode(PreviewResponseSchema, res)),
    )

  const submitEdit: CosenseApiShape['submitEdit'] = (project, previewId) =>
    request(`/api/pages/v2/${project}/page-edit-for-ai/submit`, {
      method: 'POST',
      body: { previewId },
    }).pipe(Effect.flatMap((res) => decode(SubmitResponseSchema, res)))

  return {
    me,
    projects,
    listPages,
    getPage,
    relatedPages,
    searchFullText,
    searchVector,
    searchTitles,
    previewEdit,
    submitEdit,
  }
}
