// Response shapes are parsed leniently (narrow hand-written checks, unknown fields ignored)
// rather than with a schema library — see docs/ARCHITECTURE.md "Read エンドポイント".

export interface Me {
  id: string
  name: string
  displayName: string
  email?: string
}

export interface ProjectSummary {
  id: string
  name: string
  displayName: string
  publicVisible: boolean
  isMember: boolean
  usersCount: number
  created: number
  updated: number
}

export interface UserRef {
  id: string
  name?: string
  displayName?: string
}

export interface PageSummary {
  id: string
  title: string
  image: string | null
  descriptions: string[]
  user?: UserRef | null
  linked: number
  views: number
  linesCount: number
  charsCount: number
  created: number
  updated: number
}

export interface PageDetailLine {
  id: string
  text: string
}

/**
 * getPage() contract. cosense-cli's readPage (src/commands/readPage.ts) shows that the
 * server returns HTTP 200 with `persistent: false` for a title that has no real page yet
 * (a template response whose id/commitId/lines[].id are fake and unsafe to use as preview
 * anchors — cosense-cli strips them client-side for exactly this reason). @chatora/core's
 * getPage() folds that case into `null` too, so callers get one non-existent-page signal
 * (matching the architecture doc's "404 → null") without ever seeing a fake anchor id.
 */
export interface PageDetail {
  id: string
  title: string
  commitId: string
  lines: PageDetailLine[]
}

export interface RelatedPage {
  id: string
  title: string
  titleLc: string
  image: string | null
  descriptions: string[]
  linksLc: string[]
  linked: number
  pageRank: number
  updated: number
  relation?: 'outgoing' | 'incoming' | 'bidirectional'
}

export interface RelatedPages {
  links1hop: RelatedPage[]
  links2hop: RelatedPage[]
}

export interface SearchResultPage {
  id: string
  title: string
  words: string[]
  lines: string[]
  views: number
  linked: number
  updated: number
}

export interface SearchResult {
  count: number
  existsExactTitleMatch: boolean
  pages: SearchResultPage[]
}

export interface VectorResultPage {
  title: string
  image: string | null
  score: number
  exists: boolean
  id?: string
  linked?: number
}

export interface VectorResult {
  pages: VectorResultPage[]
}

export interface TitleEntry {
  id: string
  title: string
  titleLc: string
  updated: number
  image: string | null
}

// RawChange / preview / submit shapes verified against cosense-cli
// src/commands/previewEdit.ts and src/commands/submitEdit.ts.

export interface RawInsertChange {
  _insert: string // anchor lineId, or '_end' to append
  lines: { id: string; text: string }
}

export interface RawUpdateChange {
  _update: string // lineId
  lines: { text: string }
}

export interface RawDeleteChange {
  // No `lines` field at all — cosense-cli's RawDeleteChange is exactly `{_delete: string}`.
  _delete: string // lineId
}

export type RawChange = RawInsertChange | RawUpdateChange | RawDeleteChange

export interface PreviewEditBody {
  pageId?: string
  changes: RawChange[]
}

export interface PagePreview {
  title?: string
  persistent?: boolean
  lines?: PageDetailLine[]
}

export interface PreviewResponse {
  previewId: string
  expireAt: string
  pagePreview: PagePreview | null
}

export interface SubmitResponse {
  commitId: string
  page: { title: string } | null
  titleChanged?: { from: string; to: string }
}
