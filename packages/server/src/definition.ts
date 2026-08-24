import { parseLine } from '@cosense-toolbox/parser'
import { visit } from '@cosense-toolbox/parser/utils'
import { formatUri } from './uriScheme'

/**
 * Cursor -> the URL a browser should open, for the external notations on one line.
 * `null` when the cursor is on something that resolves to a page instead (see
 * `findDefinitionTarget`) or to nothing at all.
 */
export const findUrlTarget = (lineText: string, character: number): string | null => {
  const line = parseLine(lineText)
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
): { project: string; title: string } | null => {
  const line = parseLine(lineText)
  let target: { project: string; title: string } | null = null

  visit(line, (node) => {
    const inRange = character >= node.position.start.column && character < node.position.end.column
    if (!inRange) return undefined

    if (node.type === 'internalLink') target = { project: currentProject, title: node.target }
    else if (node.type === 'hashtag') target = { project: currentProject, title: node.value }
    else if (node.type === 'projectLink') target = { project: node.project, title: node.title }
    return target ? 'exit' : undefined
  })

  return target
}

/** Builds the LSP Location for a definition target: the top of the target page. */
export const definitionLocation = (target: { project: string; title: string }) => ({
  uri: formatUri(target.project, target.title),
  range: { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } },
})
