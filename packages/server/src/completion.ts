import type { Page } from '@cosense-toolbox/parser'
import { normalizeLineEndings, parse } from '@cosense-toolbox/parser'
import { visit } from '@cosense-toolbox/parser/utils'
import {
  type CompletionItem,
  CompletionItemKind,
  type Range,
  type TextEdit,
} from 'vscode-languageserver/node'
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
 * Substring-filters and sorts titles for a completion query: startsWith matches first, then
 * the rest, each bucket keeping stable relative order; capped at MAX_COMPLETION_ITEMS.
 */
export const filterAndSortTitles = <T extends { title: string }>(
  titles: readonly T[],
  query: string,
  options: { noSpaces?: boolean } = {},
): T[] => {
  const q = normalizeForMatch(query)
  const pool = options.noSpaces ? titles.filter((t) => !/\s/.test(t.title)) : titles
  const matched = pool.filter((t) => normalizeForMatch(t.title).includes(q))
  const withStarts = matched.map((t) => ({ t, starts: normalizeForMatch(t.title).startsWith(q) }))
  withStarts.sort((a, b) => Number(b.starts) - Number(a.starts))
  return withStarts.slice(0, MAX_COMPLETION_ITEMS).map((x) => x.t)
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

/** Fetches the title index (via state's cache) and builds LSP CompletionItems. Impure — not unit tested. */
export const buildCompletionItems = async (
  state: ServerState,
  project: string,
  line: number,
  detection: CompletionDetection,
): Promise<CompletionItem[]> => {
  const titles = await state.getTitles(project)
  const matches = filterAndSortTitles(titles, detection.query, {
    noSpaces: detection.kind === 'hashtag',
  })

  return matches.map((entry, index) => {
    const edit = buildTextEdit(line, detection, entry.title)
    const item: CompletionItem = {
      label: entry.title,
      kind: CompletionItemKind.Reference,
      filterText: entry.title,
      sortText: String(index).padStart(4, '0'),
      textEdit: edit as TextEdit,
    }
    return item
  })
}
