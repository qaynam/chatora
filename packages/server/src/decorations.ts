import { normalizeLineEndings, parse } from '@cosense-toolbox/parser'
import { visit } from '@cosense-toolbox/parser/utils'
import { parseOptions } from './notations'

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
}

export const computeConcealRanges = (text: string): ConcealRange[] => {
  const page = parse(text, parseOptions())
  // Columns index UTF-16 code units, the same unit JS string indexing uses, so
  // these lines can be sliced with the parser's own column numbers.
  const docLines = normalizeLineEndings(text).split('\n')
  const out: ConcealRange[] = []
  const push = (line: number, startChar: number, endChar: number): void => {
    if (endChar > startChar) out.push({ line, startChar, endChar })
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
          push(start.line, start.column, first.position.start.column)
          push(end.line, last.position.end.column, end.column)
        }
        return 'skip'
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
