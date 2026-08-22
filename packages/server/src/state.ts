import type { Credential, Me, TitleEntry } from '@chatora/core'
import { CosenseApi, resolveCredential } from '@chatora/core'

export interface BasePageState {
  readonly project: string
  readonly title: string
  readonly pageId?: string
  readonly commitId?: string
  readonly baseLines: readonly { id: string; text: string }[]
  readonly exists: boolean
}

interface TitlesCacheEntry {
  readonly fetchedAt: number
  readonly titles: readonly TitleEntry[]
}

const TITLES_CACHE_TTL_MS = 60_000
// Credential resolution has no project scope for these calls (see docs/ARCHITECTURE.md
// resolveCredential(origin, project?)) — a distinct key from any real project name.
const NO_PROJECT_KEY = '\0no-project'

/**
 * Session state for one LSP connection: origin, cached credential/CosenseApi per project
 * (a project may resolve to its own service-account credential), the once-per-session
 * verified user, per-project title caches (for completion), and open pages' base diff state
 * keyed by cosense:// URI (see openPage/savePage in pages.ts).
 */
export class ServerState {
  readonly origin: string
  private credentialCache = new Map<string, Credential | null>()
  private apiCache = new Map<string, CosenseApi>()
  private titlesCache = new Map<string, TitlesCacheEntry>()
  private pages = new Map<string, BasePageState>()
  verifiedUser: Me | undefined
  private verifyFailed = false

  constructor(origin: string) {
    this.origin = origin
  }

  private credentialKey(project?: string): string {
    return project ?? NO_PROJECT_KEY
  }

  async getCredential(project?: string): Promise<Credential | null> {
    const key = this.credentialKey(project)
    const cached = this.credentialCache.get(key)
    if (cached !== undefined) return cached
    const credential = await resolveCredential(this.origin, project)
    this.credentialCache.set(key, credential)
    return credential
  }

  async getApi(project?: string): Promise<CosenseApi | null> {
    const key = this.credentialKey(project)
    const cached = this.apiCache.get(key)
    if (cached) return cached
    const credential = await this.getCredential(project)
    if (!credential) return null
    const api = new CosenseApi({ origin: this.origin, credential })
    this.apiCache.set(key, api)
    return api
  }

  /** Uncached: builds a CosenseApi for an explicit credential (login verifies before caching). */
  apiFor(credential: Credential): CosenseApi {
    return new CosenseApi({ origin: this.origin, credential })
  }

  /** Login/logout invalidate every cache — a fresh credential may resolve differently per project. */
  invalidateCredentials(): void {
    this.credentialCache.clear()
    this.apiCache.clear()
    this.titlesCache.clear()
    this.verifiedUser = undefined
    this.verifyFailed = false
  }

  /** authStatus calls this — verifies /api/users/me at most once per session (until invalidated). */
  async ensureVerified(): Promise<Me | undefined> {
    if (this.verifiedUser || this.verifyFailed) return this.verifiedUser
    const api = await this.getApi()
    if (!api) return undefined
    try {
      this.verifiedUser = await api.me()
    } catch {
      this.verifyFailed = true
    }
    return this.verifiedUser
  }

  async getTitles(project: string): Promise<readonly TitleEntry[]> {
    const cached = this.titlesCache.get(project)
    if (cached && Date.now() - cached.fetchedAt < TITLES_CACHE_TTL_MS) return cached.titles
    const api = await this.getApi(project)
    if (!api) return []
    const titles = await api.searchTitles(project)
    this.titlesCache.set(project, { fetchedAt: Date.now(), titles })
    return titles
  }

  getPage(uri: string): BasePageState | undefined {
    return this.pages.get(uri)
  }

  setPage(uri: string, state: BasePageState): void {
    this.pages.set(uri, state)
  }

  deletePage(uri: string): void {
    this.pages.delete(uri)
  }
}
