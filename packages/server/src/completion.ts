import type { HttpClient } from '@chatora/core'
import type { Page } from '@cosense-toolbox/parser'
import { normalizeLineEndings, parse } from '@cosense-toolbox/parser'
import { visit } from '@cosense-toolbox/parser/utils'
import { Duration, Effect, Fiber } from 'effect'
import {
  type CompletionItem,
  CompletionItemKind,
  type Range,
  type TextEdit,
} from 'vscode-languageserver/node'
import { Asearch } from './asearch'
import { SessionState } from './state'

export interface CompletionDetection {
  readonly kind: 'link' | 'hashtag'
  readonly query: string
  readonly replaceStart: number
  readonly replaceEnd: number
  /** `replaceStart` up to the cursor — what the client sees as already typed. */
  readonly typedText: string
}

// Link completion fires only when the cursor sits inside a *closed* bracket pair
// `[...|...]` (Cosense behavior — autopairs/the web editor close the bracket the moment
// it's typed). Backward scan: hitting `]` first means the cursor is past a pair; a `[`
// that is the second half of `[[` belongs to `[[...]]` (bold/large-image), not a link.
// Forward scan: the closing `]` must exist ahead on the same line; accepting a candidate
// replaces the whole pair.
const detectLink = (lineText: string, character: number): CompletionDetection | null => {
  for (let i = character - 1; i >= 0; i--) {
    const ch = lineText[i]
    if (ch === ']') return null
    if (ch === '[') {
      if (lineText[i - 1] === '[') return null
      for (let j = character; j < lineText.length; j++) {
        const cj = lineText[j]
        if (cj === '[') return null
        if (cj === ']') {
          return {
            kind: 'link',
            // The whole bracket content, not just up to the cursor: Cosense
            // treats the link text as one unit, so the candidates are the
            // same wherever the cursor sits inside the pair.
            query: lineText.slice(i + 1, j),
            replaceStart: i,
            replaceEnd: j + 1,
            typedText: lineText.slice(i, character),
          }
        }
      }
      return null
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
    typedText: lineText.slice(i, character),
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

/** Results below which the fuzzy tier is worth its full scan of the pool. */
const FUZZY_FALLBACK_THRESHOLD = 10

// Keyed by the titles array *identity*: SessionState hands back the same array for the life
// of its cache entry, so the index is rebuilt exactly when the titles are refetched — not on
// every keystroke, which for a large project cost more than the search itself.
const indexByTitles = new WeakMap<readonly TitleEntryLike[], Candidate[]>()

const candidateIndex = (titles: readonly TitleEntryLike[]): Candidate[] => {
  const cached = indexByTitles.get(titles)
  if (cached !== undefined) return cached
  const built = buildCandidateIndex(titles)
  indexByTitles.set(titles, built)
  return built
}

// How long a completion will wait on vector search before answering from the
// local index alone. Short enough that a keystroke never visibly stalls.
const VECTOR_BUDGET = Duration.millis(120)

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
  // Fuzzy is typo tolerance, not a way to pad the list: it only runs when the
  // literal tiers came up short, since it costs a full scan of the pool. A
  // 1-character query is excluded outright — it matches nearly everything.
  // Both error budgets are collected in one pass; two `filter`s over a large
  // pool measurably outweighed the search itself.
  if (result.length < FUZZY_FALLBACK_THRESHOLD && q.length >= 2) {
    const matcher = Asearch(q)
    const oneError: Candidate[] = []
    const twoErrors: Candidate[] = []
    for (const c of pool) {
      if (seen.has(c.key)) continue
      if (matcher(c.key, 1)) oneError.push(c)
      else if (matcher(c.key, 2)) twoErrors.push(c)
    }
    take(oneError)
    if (result.length < MAX_COMPLETION_ITEMS) take(twoErrors)
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

export const toCompletionItems = (
  matches: readonly Candidate[],
  line: number,
  detection: CompletionDetection,
): CompletionItem[] =>
  matches.map((entry, index) => {
    const edit = buildTextEdit(line, detection, entry.title)
    const { kind, detail } = candidateItemFields(entry.exists)
    const item: CompletionItem = {
      label: entry.title,
      kind,
      // The typed text trivially matches itself, so no client can re-filter
      // this list. Ranking here is fuzzy + semantic; a prefix filter (Neovim's
      // built-in completion applies one to filterText) would drop most of it
      // and close the menu, ending the isIncomplete re-query loop with it.
      filterText: detection.typedText,
      sortText: String(index).padStart(4, '0'),
      textEdit: edit as TextEdit,
    }
    if (detail !== undefined) item.detail = detail
    return item
  })

/**
 * Fetches candidates and builds LSP CompletionItems. Impure — not unit tested (the pure
 * ranking/merge functions above are). Primary source is Cosense's vector (semantic) title
 * search — the same endpoint the real web editor queries on every keystroke (verified via a
 * HAR capture of scrapbox.io) — with the local title index (exact/prefix/substring/asearch
 * tiers) merged in behind it, and as the sole source when vector search is unavailable
 * (HTTP 490/404, a title/titles fetch failure, or an empty query).
 */
export const buildCompletionItems = (
  project: string,
  line: number,
  detection: CompletionDetection,
): Effect.Effect<CompletionItem[], never, SessionState | HttpClient> =>
  Effect.gen(function* () {
    const session = yield* SessionState
    const noSpaces = detection.kind === 'hashtag'
    const titles = yield* session.getTitles(project).pipe(Effect.catchAll(() => Effect.succeed([])))
    const local = rankCandidates(candidateIndex(titles), detection.query, { noSpaces })

    let matches = local
    if (detection.query !== '') {
      // Vector search is a network round-trip on a keystroke path. Run it as a
      // daemon so a slow one can't hold up the menu — it still finishes and
      // fills the cache, and `isIncomplete` means the next keystroke re-asks
      // and gets it instantly.
      const fiber = yield* Effect.forkDaemon(
        session
          .searchVectorCached(project, detection.query)
          .pipe(Effect.catchAll(() => Effect.succeed([] as readonly VectorPageLike[]))),
      )
      const vectorPages = yield* Fiber.join(fiber).pipe(
        Effect.timeout(VECTOR_BUDGET),
        Effect.catchAll(() => Effect.succeed([] as readonly VectorPageLike[])),
      )
      let vector = vectorCandidates(vectorPages)
      if (noSpaces) vector = vector.filter((c) => !/\s/.test(c.title))
      if (vector.length > 0) matches = mergeCandidates(vector, local)
    }

    return toCompletionItems(matches, line, detection)
  })
