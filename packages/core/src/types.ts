// Response shapes are parsed leniently by CosenseApi (effect Schema with every field
// optional-with-default, see schemas.ts): unknown fields are ignored, missing fields fall
// back to a zero value — see docs/ARCHITECTURE.md "Read エンドポイント".

/** A saved page filter from Cosense's list UI, e.g. `{ type: 'icon', value: 'qaynam' }`. */
export interface PageFilter {
  readonly type: string
  readonly value: string
}

export interface Me {
  readonly id: string
  readonly name: string
  readonly displayName: string
  readonly email?: string
  readonly photo?: string
  readonly pageFilters: readonly PageFilter[]
}

export interface ProjectSummary {
  readonly id: string
  readonly name: string
  readonly displayName: string
  readonly publicVisible: boolean
  readonly isMember: boolean
  readonly usersCount: number
  readonly created: number
  readonly updated: number
}

export interface ProjectDetail {
  readonly id: string
  readonly name: string
  readonly displayName: string
  /** `'gyazo'` or `'gcs'` — where the web client sends a pasted image. */
  readonly uploadImageTo: string
  readonly uploadFileTo: string
  /** Gyazo Teams the project uploads into; null for a project on plain Gyazo. */
  readonly gyazoTeamsName: string | null
}

export interface UserRef {
  readonly id: string
  readonly name?: string
  readonly displayName?: string
}

export interface PageSummary {
  readonly id: string
  readonly title: string
  readonly image: string | null
  readonly descriptions: readonly string[]
  readonly user?: UserRef | null
  readonly linked: number
  readonly views: number
  readonly linesCount: number
  readonly charsCount: number
  readonly created: number
  readonly updated: number
  /** Requesting user's last visit (unix seconds); 0 when never visited. `updated > accessed` means unread. */
  readonly accessed: number
  /** Sort weight for pinned pages; 0 means not pinned. */
  readonly pin: number
}

export interface PageDetailLine {
  readonly id: string
  readonly text: string
}

/**
 * getPage() contract. cosense-cli's readPage (src/commands/readPage.ts) shows that the
 * server returns HTTP 200 with `persistent: false` for a title that has no real page yet
 * (a template response whose id/commitId/lines[].id are fake and unsafe to use as preview
 * anchors — cosense-cli strips them client-side for exactly this reason). @chatora/core's
 * getPage() folds that case into `Option.none()` too, alongside a real HTTP 404, so callers
 * get one non-existent-page signal without ever seeing a fake anchor id.
 */
export interface PageDetail {
  readonly id: string
  readonly title: string
  readonly commitId: string
  readonly lines: readonly PageDetailLine[]
  /** Unix seconds. */
  readonly created: number
  /** Unix seconds. */
  readonly updated: number
  /** Unix seconds of the requesting user's last visit; 0 when never visited. */
  readonly accessed: number
  readonly views: number
  readonly linked: number
  readonly linesCount: number
  readonly charsCount: number
  /** Sort weight for pinned pages; 0 means not pinned. */
  readonly pin: number
  readonly pageRank: number
  /** Stored revisions — the web page menu's ページ履歴. */
  readonly snapshotCount: number
  readonly lastUpdateUser?: UserRef | null
}

export interface RelatedPage {
  readonly id: string
  readonly title: string
  readonly titleLc: string
  readonly image: string | null
  readonly descriptions: readonly string[]
  readonly linksLc: readonly string[]
  readonly linked: number
  readonly pageRank: number
  readonly updated: number
  readonly relation?: 'outgoing' | 'incoming' | 'bidirectional'
}

export interface RelatedPages {
  readonly links1hop: readonly RelatedPage[]
  readonly links2hop: readonly RelatedPage[]
}

export interface SearchResultPage {
  readonly id: string
  readonly title: string
  readonly words: readonly string[]
  readonly lines: readonly string[]
  readonly views: number
  readonly linked: number
  readonly updated: number
}

export interface SearchResult {
  readonly count: number
  readonly existsExactTitleMatch: boolean
  readonly pages: readonly SearchResultPage[]
}

export interface VectorResultPage {
  readonly title: string
  readonly image: string | null
  readonly score: number
  readonly exists: boolean
  readonly id?: string
  readonly linked?: number
}

export interface VectorResult {
  readonly pages: readonly VectorResultPage[]
}

export interface TitleEntry {
  readonly id: string
  readonly title: string
  readonly titleLc: string
  readonly updated: number
  readonly image: string | null
}

// RawChange / preview / submit shapes verified against cosense-cli
// src/commands/previewEdit.ts and src/commands/submitEdit.ts.

export interface RawInsertChange {
  readonly _insert: string // anchor lineId, or '_end' to append
  readonly lines: { readonly id: string; readonly text: string }
}

export interface RawUpdateChange {
  readonly _update: string // lineId
  readonly lines: { readonly text: string }
}

export interface RawDeleteChange {
  // No `lines` field at all — cosense-cli's RawDeleteChange is exactly `{_delete: string}`.
  readonly _delete: string // lineId
}

export type RawChange = RawInsertChange | RawUpdateChange | RawDeleteChange

export interface PreviewEditBody {
  readonly pageId?: string
  readonly changes: readonly RawChange[]
}

export interface PagePreview {
  readonly title?: string
  readonly persistent?: boolean
  readonly lines?: readonly PageDetailLine[]
}

export interface PreviewResponse {
  readonly previewId: string
  readonly expireAt: string
  readonly pagePreview: PagePreview | null
}

export interface SubmitResponse {
  readonly commitId: string
  readonly page: { readonly title: string } | null
  readonly titleChanged?: { readonly from: string; readonly to: string }
}
