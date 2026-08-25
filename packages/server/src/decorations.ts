import { normalizeLineEndings, parse } from '@cosense-toolbox/parser'
import { visit } from '@cosense-toolbox/parser/utils'
import { notationNameForDecoration, parseOptions } from './notations'

/**
 * Ranges of notation markup to conceal in the editor (render-markdown.nvim
 * style: hidden everywhere except the cursor line, which Neovim's own
 * conceallevel/concealcursor machinery reveals). Columns are UTF-16 code
 * units, same as the parser's/LSP's position encoding — the Lua side converts
 * to byte columns per line.
 */
export interface ConcealRange {
  line: number
  startChar: number
  endChar: number
  /** Set on the opening marker of a user-defined notation; the client replaces the range with that notation's icon. */
  notation?: string
}

export const computeConcealRanges = (text: string): ConcealRange[] => {
  const page = parse(text, parseOptions())
  // Columns index UTF-16 code units, the same unit JS string indexing uses, so
  // these lines can be sliced with the parser's own column numbers.
  const docLines = normalizeLineEndings(text).split('\n')
  const out: ConcealRange[] = []
  const push = (line: number, startChar: number, endChar: number, notation?: string): void => {
    if (endChar > startChar)
      out.push(notation ? { line, startChar, endChar, notation } : { line, startChar, endChar })
  }

  visit(page, (node) => {
    const { start, end } = node.position
    if (start.line !== end.line) return undefined

    switch (node.type) {
      case 'decoration': {
        // [* text] / [/ text] / [[text]] … — hide the marker prefix and the
        // closing bracket(s), keeping the styled children visible.
        const first = node.children[0]
        const last = node.children[node.children.length - 1]
        if (first && last) {
          // Only the opening marker carries `notation`; an official decoration's
          // marker (*, /, -, _) never resolves to one (see notationNameForDecoration).
          push(
            start.line,
            start.column,
            first.position.start.column,
            notationNameForDecoration(node),
          )
          push(end.line, last.position.end.column, end.column)
        }
        // Descend, so a link nested in a decoration (`[* [nuclear]]`) loses its own
        // brackets too. The ranges never overlap: this hid only what precedes the first
        // child and follows the last.
        return undefined
      }
      case 'internalLink':
      case 'projectLink':
        push(start.line, start.column, start.column + 1)
        push(end.line, end.column - 1, end.column)
        return 'skip'
      case 'externalLink': {
        // A bare URL spans exactly its label and has no markup to hide.
        if (end.column - start.column <= node.label.length) return 'skip'
        push(start.line, start.column, start.column + 1)
        push(end.line, end.column - 1, end.column)

        // `[label url]` / `[url label]` show only the label in Cosense, with
        // the URL living in the href. Hide the URL and the space that
        // separates it, so a long link reads as its title. `[url]` (label ===
        // target) is left alone — hiding it would leave nothing to click.
        const inner = docLines[start.line]?.slice(start.column + 1, end.column - 1) ?? ''
        const target = node.target
        if (target !== node.label) {
          if (inner.startsWith(`${target} `)) {
            push(start.line, start.column + 1, start.column + 1 + target.length + 1)
          } else if (inner.endsWith(` ${target}`)) {
            push(start.line, end.column - 1 - target.length - 1, end.column - 1)
          }
        }
        return 'skip'
      }
      case 'inlineCode':
        push(start.line, start.column, start.column + 1)
        push(end.line, end.column - 1, end.column)
        return 'skip'
      default:
        return undefined
    }
  })

  return out
}
