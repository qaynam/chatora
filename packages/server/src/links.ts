import { normalizeLineEndings, parse } from '@cosense-toolbox/parser'
import { visit } from '@cosense-toolbox/parser/utils'
import { parseOptions } from './notations'

/**
 * A link to a page in the same project. Columns are UTF-16 code units, matching the rest of
 * the LSP surface.
 */
export interface InternalLink {
  readonly line: number
  readonly startChar: number
  readonly endChar: number
  readonly title: string
}

/**
 * Every `[title]` and `#tag` pointing inside the project, in document order.
 *
 * Cosense treats a hashtag as a link to the page of that name, so a `#tag` nobody has
 * written a page for is as empty as a bracketed one — both draw red in the web UI.
 * `[/other/page]` is deliberately absent: whether it resolves is another project's index.
 */
export const computeInternalLinks = (text: string): InternalLink[] => {
  const out: InternalLink[] = []
  visit(parse(normalizeLineEndings(text), parseOptions()), ['internalLink', 'hashtag'], (node) => {
    // The two notations name their page differently: a bracketed link separates the page it
    // points at from the text it shows, a hashtag is only ever its own text.
    const title = node.type === 'hashtag' ? node.value : node.target
    if (title === '') return
    out.push({
      line: node.position.start.line,
      startChar: node.position.start.column,
      endChar: node.position.end.column,
      title,
    })
  })
  return out
}

/**
 * Cosense matches page titles case-insensitively (its own index is keyed by `titleLc`), so
 * a link only counts as empty when nothing matches it folded.
 */
export const titleKey = (title: string): string => title.toLowerCase()
