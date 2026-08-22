import type { Page } from '@cosense-toolbox/parser'
import { normalizeLineEndings, parse } from '@cosense-toolbox/parser'
import { visit } from '@cosense-toolbox/parser/utils'
import {
  type CompletionItem,
  CompletionItemKind,
  type Range,
  type TextEdit,
} from 'vscode-languageserver/node'
import { Asearch } from './asearch'
import type { ServerState } from './state'

export interface CompletionDetection {
  readonly kind: 'link' | 'hashtag'
  readonly query: string
  readonly replaceStart: number
  readonly replaceEnd: number
}

// Scans backward from the cursor for an unclosed `[`. Hitting `]` first means the bracket
// pair is already closed (cursor sits after it) -> not a completion context. A `[` that is
// itself the second half of `[[` belongs to `[[...]]` (bold/large-image), not a link.
const detectLink = (lineText: string, character: number): CompletionDetection | null => {
  for (let i = character - 1; i >= 0; i--) {
    const ch = lineText[i]
    if (ch === ']') return null
    if (ch === '[') {
      if (lineText[i - 1] === '[') return null
      const replaceEnd = lineText[character] === ']' ? character + 1 : character
      return { kind: 'link', query: lineText.slice(i + 1, character), replaceStart: i, replaceEnd }
    }
  }
  return null
}

// A run of non-whitespace/non-bracket/non-# characters touching the cursor, whose run
// terminates in a `#` at a valid tag boundary (line start, or preceded by whitespace) —
// mirrors parser src/inline/constructs/hashtag.ts (TAG_NAME_RE / isTagBoundary).
const detectHashtag = (lineText: string, character: number): CompletionDetection | null => {
  let i = character - 1
  while (i >= 0 && /[^\s[\]#]/.test(lineText[i] as string)) i--
  if (i < 0 || lineText[i] !== '#') return null
  const boundaryOk = i === 0 || /\s/.test(lineText[i - 1] as string)
  if (!boundaryOk) return null
  return {
    kind: 'hashtag',
    query: lineText.slice(i + 1, character),
    replaceStart: i,
    replaceEnd: character,
  }
}

/** Pure line/cursor -> completion trigger detection. No AST, no I/O. */
export const detectCompletion = (lineText: string, character: number): CompletionDetection | null =>
  detectLink(lineText, character) ?? detectHashtag(lineText, character)

// Cursor must be strictly between the backticks (not touching them) to count as "inside".
const isSuppressed = (page: Page, line: number, character: number): boolean => {
  let suppressed = false
  visit(page, (node) => {
    if (node.type === 'codeBlock') {
      if (line >= node.position.start.line && line <= node.position.end.line) suppressed = true
      return 'skip'
    }
    if (node.type === 'inlineCode') {
      if (
        line === node.position.start.line &&
        character > node.position.start.column &&
        character < node.position.end.column
      ) {
        suppressed = true
      }
      return 'skip'
    }
    return undefined
  })
  return suppressed
}

/**
 * The caller-level entry point: parses the whole document, suppresses completion inside
 * CodeBlock / inlineCode spans, then delegates to the pure detectCompletion for the cursor's
 * own line.
 */
export const detectCompletionInDocument = (
  text: string,
  position: { line: number; character: number },
): CompletionDetection | null => {
  const page = parse(text)
  if (isSuppressed(page, position.line, position.character)) return null
  const lineText = normalizeLineEndings(text).split('\n')[position.line] ?? ''
  return detectCompletion(lineText, position.character)
}

/** NFKC + lowercase + space/`_` equivalence, per docs/ARCHITECTURE.md's completion rules. */
export const normalizeForMatch = (s: string): string =>
  s.normalize('NFKC').toLowerCase().replace(/[_ ]/g, ' ')

const MAX_COMPLETION_ITEMS = 50

/**
 * Permissive shape for what `/search/titles` actually sends. @chatora/core's `TitleEntry`
 * declares `id`/`titleLc`/`updated`/`image` as required, but the real payload is parsed with
 * a bare `as` cast (no runtime validation — see CosenseApi.searchTitles) and the e2e fake
 * server's fixture omits everything but `title`, so treat every field but `title` as
 * possibly absent here. `links` is each page's outgoing link targets (verified against
 * cosense-app-client's TitleEntrySchema — see the response shape note in the task report).
 */
export interface TitleEntryLike {
  readonly title: string
  readonly updated?: number
  readonly links?: readonly string[]
}

/** One completion candidate: an existing page, or a link target with no page yet ("red link"). */
export interface Candidate {
  readonly title: string
  /** normalizeForMatch(title) — the dedupe/match key. */
  readonly key: string
  readonly exists: boolean
  readonly updated: number | undefined
}

/**
 * Candidate set = page titles ∪ outgoing link targets, deduped by normalizeForMatch key.
 * Pages are indexed first so a link target sharing a page's normalized title keeps the
 * page's real casing and `exists: true` (link entries never overwrite an existing key).
 */
export const buildCandidateIndex = (titles: readonly TitleEntryLike[]): Candidate[] => {
  const byKey = new Map<string, Candidate>()
  for (const entry of titles) {
    const key = normalizeForMatch(entry.title)
    byKey.set(key, { title: entry.title, key, exists: true, updated: entry.updated })
  }
  for (const entry of titles) {
    for (const link of entry.links ?? []) {
      const key = normalizeForMatch(link)
      if (byKey.has(key)) continue
      byKey.set(key, { title: link, key, exists: false, updated: undefined })
    }
  }
  return [...byKey.values()]
}

/**
 * Tiered ranking for a completion query: exact, then prefix, then substring, then
 * Asearch-fuzzy (1 error, then 2 errors) — each tier only run once the stricter ones leave
 * room under the cap, deduped across tiers by key. Within a tier, sort by `updated` desc
 * when the pool has updated data at all; otherwise keep API/insertion order (stable sort).
 * An empty query returns the pool itself in that same recency-or-API order, capped.
 */
export const rankCandidates = (
  candidates: readonly Candidate[],
  query: string,
  options: { noSpaces?: boolean } = {},
): Candidate[] => {
  const pool = options.noSpaces ? candidates.filter((c) => !/\s/.test(c.title)) : candidates
  const hasUpdated = pool.some((c) => c.updated !== undefined)
  const byRecency = (a: Candidate, b: Candidate): number =>
    hasUpdated ? (b.updated ?? 0) - (a.updated ?? 0) : 0

  const q = normalizeForMatch(query)
  if (q.length === 0) return [...pool].sort(byRecency).slice(0, MAX_COMPLETION_ITEMS)

  const seen = new Set<string>()
  const result: Candidate[] = []
  const take = (matched: readonly Candidate[]): void => {
    for (const c of [...matched].sort(byRecency)) {
      if (result.length >= MAX_COMPLETION_ITEMS) return
      if (seen.has(c.key)) continue
      seen.add(c.key)
      result.push(c)
    }
  }

  take(pool.filter((c) => c.key === q))
  if (result.length < MAX_COMPLETION_ITEMS) {
    take(pool.filter((c) => c.key !== q && c.key.startsWith(q)))
  }
  if (result.length < MAX_COMPLETION_ITEMS) {
    take(pool.filter((c) => !c.key.startsWith(q) && c.key.includes(q)))
  }
  if (result.length < MAX_COMPLETION_ITEMS) {
    const matcher = Asearch(q)
    take(pool.filter((c) => !seen.has(c.key) && matcher(c.key, 1)))
    if (result.length < MAX_COMPLETION_ITEMS) {
      take(pool.filter((c) => !seen.has(c.key) && matcher(c.key, 2)))
    }
  }

  return result
}

const buildTextEdit = (
  line: number,
  detection: CompletionDetection,
  title: string,
): { range: Range; newText: string } => ({
  range: {
    start: { line, character: detection.replaceStart },
    end: { line, character: detection.replaceEnd },
  },
  newText: detection.kind === 'link' ? `[${title}]` : `#${title}`,
})

/**
 * Maps a candidate's existence to its LSP presentation: an existing page is a plain
 * Reference; a link target with no page yet ("red link" in Cosense) is a subtly-marked
 * Text item, so the client can still show it differently without shouting about it.
 */
export const candidateItemFields = (
  exists: boolean,
): { kind: CompletionItemKind; detail?: string } =>
  exists
    ? { kind: CompletionItemKind.Reference }
    : { kind: CompletionItemKind.Text, detail: '(new)' }

/** The fields of a vector-search result page that completion consumes. */
export interface VectorPageLike {
  readonly title: string
  readonly exists?: boolean
}

/** Vector results → candidates, preserving the server's score order. */
export const vectorCandidates = (pages: readonly VectorPageLike[]): Candidate[] => {
  const out: Candidate[] = []
  for (const p of pages) {
    if (typeof p.title === 'string' && p.title !== '') {
      out.push({
        title: p.title,
        key: normalizeForMatch(p.title),
        exists: p.exists !== false,
        updated: undefined,
      })
    }
  }
  return out
}

/** primary first (its order kept), then fallback entries not already present, capped. */
export const mergeCandidates = (
  primary: readonly Candidate[],
  fallback: readonly Candidate[],
  cap: number = MAX_COMPLETION_ITEMS,
): Candidate[] => {
  const seen = new Set<string>()
  const out: Candidate[] = []
  for (const list of [primary, fallback]) {
    for (const c of list) {
      if (out.length >= cap) return out
      if (seen.has(c.key)) continue
      seen.add(c.key)
      out.push(c)
    }
  }
  return out
}

/**
 * Fetches candidates and builds LSP CompletionItems. Impure — not unit tested.
 * Primary source is Cosense's vector (semantic) title search — the same endpoint the real
 * web editor queries on every keystroke (verified via a HAR capture of scrapbox.io) — with
 * the local title index (exact/prefix/substring/asearch tiers) merged in behind it, and as
 * the sole source when vector search is unavailable (HTTP 490/404) or the query is empty.
 */
export const buildCompletionItems = async (
  state: ServerState,
  project: string,
  line: number,
  detection: CompletionDetection,
): Promise<CompletionItem[]> => {
  const noSpaces = detection.kind === 'hashtag'
  const titles = await state.getTitles(project)
  const candidates = buildCandidateIndex(titles)
  const local = rankCandidates(candidates, detection.query, { noSpaces })

  let matches = local
  if (detection.query !== '') {
    try {
      let vector = vectorCandidates(await state.searchVectorCached(project, detection.query))
      if (noSpaces) vector = vector.filter((c) => !/\s/.test(c.title))
      if (vector.length > 0) matches = mergeCandidates(vector, local)
    } catch {
      // vector search unavailable for this project — local tiers already cover it
    }
  }

  return matches.map((entry: Candidate, index: number) => {
    const edit = buildTextEdit(line, detection, entry.title)
    const { kind, detail } = candidateItemFields(entry.exists)
    const item: CompletionItem = {
      label: entry.title,
      kind,
      // Must cover the typed text from textEdit.range.start (which includes the leading
      // bracket/hash), or clients that filter against that span drop every item.
      filterText: detection.kind === 'link' ? `[${entry.title}` : `#${entry.title}`,
      sortText: String(index).padStart(4, '0'),
      textEdit: edit as TextEdit,
    }
    if (detail !== undefined) item.detail = detail
    return item
  })
}
