import type { Credential } from './credentials'
import type {
  Me,
  PageDetail,
  PageSummary,
  PreviewEditBody,
  PreviewResponse,
  ProjectSummary,
  RelatedPage,
  RelatedPages,
  SearchResult,
  SubmitResponse,
  TitleEntry,
  VectorResult,
} from './types'

export class CosenseApiError extends Error {
  readonly status: number
  readonly code?: string

  constructor(params: { status: number; code?: string; message: string }) {
    super(params.message)
    this.name = 'CosenseApiError'
    this.status = params.status
    if (params.code !== undefined) this.code = params.code
  }
}

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

export interface CosenseApiOptions {
  origin: string
  credential: Credential
  fetch?: typeof fetch
}

export class CosenseApi {
  private readonly origin: string
  private readonly credential: Credential
  private readonly fetchImpl: typeof fetch

  constructor(opts: CosenseApiOptions) {
    this.origin = opts.origin
    this.credential = opts.credential
    this.fetchImpl = opts.fetch ?? fetch
  }

  // Headers per cosense-cli src/lib/request.ts buildCredentialHeaders.
  private buildHeaders(hasBody: boolean): Record<string, string> {
    const headers: Record<string, string> =
      this.credential.type === 'serviceAccount'
        ? { 'x-service-account-access-key': this.credential.value }
        : { 'x-personal-access-token': this.credential.value }
    if (hasBody) headers['Content-Type'] = 'application/json'
    return headers
  }

  // redirect: 'manual' + treat any 3xx as an error so credential headers never travel to a
  // redirect target on a different origin (architecture doc "セキュリティ / 作法"; cosense-cli
  // applies the same policy for file downloads in src/lib/request.ts downloadToFile).
  private async requestJson(
    path: string,
    init?: { method?: Method; body?: unknown },
  ): Promise<unknown> {
    const url = `${this.origin}${path}`
    const hasBody = init?.body !== undefined
    const res = await this.fetchImpl(url, {
      method: init?.method ?? 'GET',
      headers: this.buildHeaders(hasBody),
      body: hasBody ? JSON.stringify(init?.body) : undefined,
      redirect: 'manual',
    })
    if (res.status >= REDIRECT_STATUS_MIN && res.status < REDIRECT_STATUS_MAX) {
      throw new CosenseApiError({
        status: res.status,
        message: `Unexpected redirect (HTTP ${res.status})`,
      })
    }
    if (!res.ok) {
      const bodyText = await res.text().catch(() => '')
      const code = parseErrorCode(bodyText)
      const error: { status: number; code?: string; message: string } = {
        status: res.status,
        message: `HTTP ${res.status} ${res.statusText}`.trim(),
      }
      if (code !== undefined) error.code = code
      throw new CosenseApiError(error)
    }
    return res.json()
  }

  async me(): Promise<Me> {
    return (await this.requestJson('/api/users/me')) as Me
  }

  async projects(): Promise<ProjectSummary[]> {
    const data = (await this.requestJson('/api/projects')) as { projects?: ProjectSummary[] }
    return data.projects ?? []
  }

  async listPages(
    project: string,
    opts: { skip?: number; limit?: number; sort?: string } = {},
  ): Promise<{ count: number; pages: PageSummary[] }> {
    const params = new URLSearchParams()
    if (opts.sort !== undefined) params.set('sort', opts.sort)
    if (opts.limit !== undefined) params.set('limit', String(opts.limit))
    if (opts.skip !== undefined) params.set('skip', String(opts.skip))
    const query = params.toString()
    const data = (await this.requestJson(`/api/pages/${project}/${query ? `?${query}` : ''}`)) as {
      count?: number
      pages?: PageSummary[]
    }
    return { count: data.count ?? 0, pages: data.pages ?? [] }
  }

  async getPage(project: string, title: string): Promise<PageDetail | null> {
    const path = `/api/pages/v2/${project}/${encodeTitleForUrl(title)}`
    let data: {
      id?: string
      title?: string
      commitId?: string
      persistent?: boolean
      lines?: PageDetail['lines']
    }
    try {
      data = (await this.requestJson(path)) as typeof data
    } catch (err) {
      if (err instanceof CosenseApiError && err.status === 404) return null
      throw err
    }
    // persistent: false => template response for a not-yet-created page; treat as absent.
    if (data.persistent === false) return null
    return {
      id: data.id ?? '',
      title: data.title ?? title,
      commitId: data.commitId ?? '',
      lines: data.lines ?? [],
    }
  }

  async relatedPages(project: string, title: string): Promise<RelatedPages> {
    const base = `/api/pages/v2/${project}/${encodeTitleForUrl(title)}`
    const [hop1, hop2] = await Promise.all([
      this.requestJson(`${base}/links1hop`) as Promise<{ links1hop?: RelatedPage[] }>,
      this.requestJson(`${base}/links2hop`) as Promise<{ links2hop?: RelatedPage[] }>,
    ])
    return { links1hop: hop1.links1hop ?? [], links2hop: hop2.links2hop ?? [] }
  }

  async searchFullText(project: string, query: string): Promise<SearchResult> {
    const path = `/api/pages/${project}/search/query?q=${encodeURIComponent(query)}`
    const data = (await this.requestJson(path)) as {
      count?: number
      existsExactTitleMatch?: boolean
      pages?: SearchResult['pages']
    }
    return {
      count: data.count ?? 0,
      existsExactTitleMatch: data.existsExactTitleMatch ?? false,
      pages: data.pages ?? [],
    }
  }

  async searchVector(project: string, query: string): Promise<VectorResult> {
    const path = `/api/pages/${project}/search/vector/titles?q=${encodeURIComponent(query)}`
    try {
      const data = (await this.requestJson(path)) as { pages?: VectorResult['pages'] }
      return { pages: data.pages ?? [] }
    } catch (err) {
      // HTTP 490 = vector search disabled for this project (architecture doc).
      if (err instanceof CosenseApiError && err.status === 490) return { pages: [] }
      throw err
    }
  }

  async searchTitles(project: string): Promise<TitleEntry[]> {
    const data = (await this.requestJson(`/api/pages/${project}/search/titles`)) as
      | TitleEntry[]
      | { pages?: TitleEntry[] }
    return Array.isArray(data) ? data : (data.pages ?? [])
  }

  async previewEdit(project: string, body: PreviewEditBody): Promise<PreviewResponse> {
    return (await this.requestJson(`/api/pages/v2/${project}/page-edit-for-ai/preview`, {
      method: 'POST',
      body,
    })) as PreviewResponse
  }

  async submitEdit(project: string, previewId: string): Promise<SubmitResponse> {
    return (await this.requestJson(`/api/pages/v2/${project}/page-edit-for-ai/submit`, {
      method: 'POST',
      body: { previewId },
    })) as SubmitResponse
  }
}
