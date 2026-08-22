import { parse } from '@cosense-toolbox/parser'
import { visit } from '@cosense-toolbox/parser/utils'

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
  const page = parse(text)
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
      case 'externalLink':
        // Only bracketed forms ([url] / [url label] / [label url]) have
        // markup to hide; a bare URL spans exactly its label.
        if (end.column - start.column > node.label.length) {
          push(start.line, start.column, start.column + 1)
          push(end.line, end.column - 1, end.column)
        }
        return 'skip'
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
