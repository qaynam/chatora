import type { AnyNode, AnyNodeType, Decoration, Position } from '@cosense-toolbox/parser'
import { normalizeLineEndings, parse } from '@cosense-toolbox/parser'
import { visit } from '@cosense-toolbox/parser/utils'
import { notationName, notationSpecs, parseOptions } from './notations'

/**
 * Legend order is a contract with the Lua side (lua/chatora/highlight.lua defines
 * `@lsp.type.<name>.cosense` for each of these, in this exact order).
 */
export const TOKEN_TYPES = [
  'title',
  'link',
  'projectLink',
  'externalLink',
  'hashtag',
  'code',
  'codeBlock',
  'formula',
  'icon',
  'quote',
  'bold',
  'italic',
  'strike',
  'underline',
  'image',
  'table',
  // Appended after the initial legend so earlier indices stay stable.
  'bold2',
  'bold3',
] as const

// `string & {}` (not plain `string`) keeps the TOKEN_TYPES literals as editor
// autocomplete while still accepting a user-defined notation's `name`.
export type TokenType = (typeof TOKEN_TYPES)[number] | (string & {})

export interface RawToken {
  readonly line: number
  readonly char: number
  readonly length: number
  readonly type: TokenType
}

const TOKEN_TYPE_INDEX: ReadonlyMap<TokenType, number> = new Map(
  TOKEN_TYPES.map((type, index) => [type, index]),
)

// Custom notation types live past the fixed TOKEN_TYPES, at the same
// marker-ascending offsets main.ts appends to the legend it returns.
const resolveTypeIndex = (type: TokenType): number => {
  const core = TOKEN_TYPE_INDEX.get(type)
  if (core !== undefined) return core
  const custom = notationSpecs().findIndex((s) => s.name === type)
  return custom === -1 ? 0 : TOKEN_TYPES.length + custom
}

// Leaf inline node types that map 1:1 to a token type. Their position is always a single
// line (tokenize runs per physical line), so no per-line splitting is needed here.
const INLINE_TOKEN_TYPE: Partial<Record<AnyNodeType, TokenType>> = {
  internalLink: 'link',
  externalLink: 'externalLink',
  projectLink: 'projectLink',
  hashtag: 'hashtag',
  inlineCode: 'code',
  image: 'image',
  icon: 'icon',
  formula: 'formula',
}

// Mirrors parser src/block/classify.ts QUOTE_RE (`/^>\s?/`) — the AST's LineBlock doesn't
// expose the marker's own length, only `quote: boolean`, so we re-derive it from the raw
// line text (indent already known from LineBlock.indent).
const QUOTE_MARKER_RE = /^>\s?/

const quoteMarkerLength = (lineText: string, indent: number): number =>
  QUOTE_MARKER_RE.exec(lineText.slice(indent))?.[0].length ?? 0

const spanToken = (type: TokenType, position: Position): RawToken => ({
  line: position.start.line,
  char: position.start.column,
  length: position.end.column - position.start.column,
  type,
})

const decorationTokenType = (node: Decoration): TokenType | null => {
  if (node.bold) {
    // Cosense sizes emphasis by asterisk count ([*]..[*****]); @cosense-toolbox/parser's
    // Decoration.sizeLevel is 0-indexed (0 = one asterisk, verified against the installed
    // 0.1.0-beta.0). A terminal has one cell size, so weight is graded via color instead:
    // bold (*) < bold2 (**) < bold3 (*** and up).
    if (node.sizeLevel >= 2) return 'bold3'
    if (node.sizeLevel === 1) return 'bold2'
    return 'bold'
  }
  if (node.italic) return 'italic'
  if (node.strike) return 'strike'
  if (node.underline) return 'underline'
  return null
}

// A custom-notation decoration has no flags set (see notations.ts's buildRule); which
// notation it was is recovered from the source, not the AST: the marker sits right after
// the node's opening `[`.
const customDecorationTokenType = (
  node: Decoration,
  docLines: readonly string[],
): TokenType | null => {
  const marker = docLines[node.position.start.line]?.[node.position.start.column + 1]
  return marker !== undefined ? (notationName(marker) ?? null) : null
}

/** Pure AST -> tokens. No LSP delta-encoding here (see encodeTokens) so this stays unit-testable. */
export const computeTokens = (text: string): RawToken[] => {
  const normalized = normalizeLineEndings(text)
  const docLines = normalized.split('\n')
  const page = parse(normalized, parseOptions())
  const tokens: RawToken[] = []

  const pushLineSpan = (type: TokenType, startLine: number, endLine: number): void => {
    for (let line = startLine; line <= endLine; line++) {
      const lineText = docLines[line] ?? ''
      if (lineText.length > 0) tokens.push({ line, char: 0, length: lineText.length, type })
    }
  }

  visit(page, (node: AnyNode) => {
    switch (node.type) {
      case 'title':
        tokens.push(spanToken('title', node.position))
        return 'skip'
      case 'codeBlock':
        pushLineSpan('codeBlock', node.position.start.line, node.position.end.line)
        return 'skip'
      case 'table':
        pushLineSpan('table', node.position.start.line, node.position.end.line)
        return 'skip'
      case 'line':
        if (node.quote) {
          const line = node.position.start.line
          const marker = quoteMarkerLength(docLines[line] ?? '', node.indent)
          if (marker > 0) tokens.push({ line, char: node.indent, length: marker, type: 'quote' })
        }
        return undefined
      case 'decoration': {
        const type = decorationTokenType(node) ?? customDecorationTokenType(node, docLines)
        if (type) tokens.push(spanToken(type, node.position))
        return 'skip'
      }
      default: {
        const mapped = INLINE_TOKEN_TYPE[node.type]
        if (mapped) tokens.push(spanToken(mapped, node.position))
        return undefined
      }
    }
  })

  return tokens.filter((t) => t.length > 0).sort((a, b) => a.line - b.line || a.char - b.char)
}

/** LSP relative encoding: [deltaLine, deltaStartChar, length, tokenType, tokenModifiers]*. */
export const encodeTokens = (tokens: readonly RawToken[]): number[] => {
  const sorted = [...tokens].sort((a, b) => a.line - b.line || a.char - b.char)
  const data: number[] = []
  let prevLine = 0
  let prevChar = 0
  for (const token of sorted) {
    const deltaLine = token.line - prevLine
    const deltaStartChar = deltaLine === 0 ? token.char - prevChar : token.char
    data.push(deltaLine, deltaStartChar, token.length, resolveTypeIndex(token.type), 0)
    prevLine = token.line
    prevChar = token.char
  }
  return data
}
