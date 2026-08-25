import { normalizeLineEndings, parse } from '@cosense-toolbox/parser'
import { visit } from '@cosense-toolbox/parser/utils'
import { parseOptions } from './notations'

/**
 * The `>` marker of a quoted line. Columns are UTF-16 code units, same as the rest of
 * the LSP surface — the Lua side converts to byte columns per line.
 */
export interface QuoteRange {
  readonly line: number
  /** Column of the marker itself, which is where the line's indent ends. */
  readonly startChar: number
  /** First column of the quoted text: past the marker and the one space Cosense allows after it. */
  readonly endChar: number
}

// Mirrors the parser's own QUOTE_RE (src/block/classify.ts) — the AST's LineBlock exposes
// `quote: boolean` but not the marker's length, so it is re-derived from the raw line.
const QUOTE_MARKER_RE = /^>\s?/

/** 0 when the line does not start a quote at `indent`. */
export const quoteMarkerLength = (lineText: string, indent: number): number =>
  QUOTE_MARKER_RE.exec(lineText.slice(indent))?.[0].length ?? 0

/**
 * Quoted lines, in document order. Lines inside a code block are not quotes even when
 * they start with `>`, which is why this asks the parser rather than scanning the text.
 */
export const computeQuoteRanges = (text: string): QuoteRange[] => {
  const normalized = normalizeLineEndings(text)
  const docLines = normalized.split('\n')
  const out: QuoteRange[] = []

  visit(parse(normalized, parseOptions()), ['line'], (node) => {
    if (!node.quote) return
    const line = node.position.start.line
    const marker = quoteMarkerLength(docLines[line] ?? '', node.indent)
    if (marker > 0) out.push({ line, startChar: node.indent, endChar: node.indent + marker })
  })

  return out
}
