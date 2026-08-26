import { parseLine } from '@cosense-toolbox/parser'
import { visit } from '@cosense-toolbox/parser/utils'
import { parseOptions } from './notations'
import { formatUri } from './uriScheme'

/**
 * Cursor -> the URL a browser should open, for the external notations on one line.
 * `null` when the cursor is on something that resolves to a page instead (see
 * `findDefinitionTarget`) or to nothing at all.
 */
export const findUrlTarget = (lineText: string, character: number): string | null => {
  const line = parseLine(lineText, parseOptions())
  let url: string | null = null

  visit(line, (node) => {
    const inRange = character >= node.position.start.column && character < node.position.end.column
    if (!inRange) return undefined

    // `[<image url> <link url>]` puts a link *on* an image; the link is what a
    // click should follow, and the image URL is only what gets rendered.
    if (node.type === 'image') url = node.link ?? node.src
    else if (node.type === 'externalLink') url = node.target
    return url ? 'exit' : undefined
  })

  return url
}

/**
 * Cursor -> target page, for internalLink/hashtag/projectLink under the cursor on one line.
 * externalLink is deliberately not matched here — see `findUrlTarget`.
 */
export const findDefinitionTarget = (
  lineText: string,
  character: number,
  currentProject: string,
): DefinitionTarget | null => {
  const line = parseLine(lineText, parseOptions())
  let target: DefinitionTarget | null = null

  const to = (project: string, raw: string): DefinitionTarget => {
    const { title, lineId } = splitLineRef(raw)
    return { project, title, ...(lineId === undefined ? {} : { lineId }) }
  }

  visit(line, (node) => {
    const inRange = character >= node.position.start.column && character < node.position.end.column
    if (!inRange) return undefined

    if (node.type === 'internalLink') target = to(currentProject, node.target)
    else if (node.type === 'hashtag') target = to(currentProject, node.value)
    else if (node.type === 'projectLink') target = to(node.project, node.title)
    return target ? 'exit' : undefined
  })

  return target
}

export interface DefinitionTarget {
  readonly project: string
  readonly title: string
  /** Set for a `title#lineId` link, which names one line of the page rather than the page. */
  readonly lineId?: string
}

// A Cosense line id is the same 24 hex characters a page id is, and a title is free to
// contain a `#` — `[C#入門]` is one page, not a line of another — so the suffix is only a
// line reference when it has exactly that shape.
const LINE_REF_RE = /^(.*[^#])#([0-9a-f]{24})$/

/**
 * Splits `title#lineId` into the page and the line it points at. Cosense writes this form
 * when a link is made to one line of a page rather than to the page itself.
 */
export const splitLineRef = (
  target: string,
): { readonly title: string; readonly lineId?: string } => {
  const matched = LINE_REF_RE.exec(target)
  return matched ? { title: matched[1] as string, lineId: matched[2] as string } : { title: target }
}

/**
 * Builds the LSP Location for a definition target: the top of the target page, or the line
 * a `title#lineId` link names once `rowOf` has found it.
 */
export const definitionLocation = (target: { project: string; title: string }, row = 0) => ({
  uri: formatUri(target.project, target.title),
  range: { start: { line: row, character: 0 }, end: { line: row, character: 0 } },
})
