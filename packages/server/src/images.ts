import type { AnyNode } from '@cosense-toolbox/parser'
import { asImageSrc, parse } from '@cosense-toolbox/parser'
import { visit } from '@cosense-toolbox/parser/utils'
import { parseOptions } from './notations'

/**
 * A drawable target found in a page's notation: an image link or an icon.
 * Columns are UTF-16 code units, same as `chatora/decorations` — the Lua
 * side converts to byte columns per line.
 */
export interface ImageTarget {
  readonly line: number
  readonly startChar: number
  /** For `kind: 'icon'` this is the raw icon user (same value as `iconUser`), not a URL — the caller builds the icon URL itself. */
  readonly src: string
  readonly kind: 'image' | 'icon'
  readonly iconUser?: string
  /** True when the node is the only non-whitespace child of its line (or the title line). */
  readonly standalone: boolean
}

const isWhitespaceText = (node: AnyNode): boolean =>
  node.type === 'text' && node.value.trim() === ''

/**
 * The parser's `isImageUrl` matches on the `#.png`-style suffix alone, with no scheme check,
 * so `[?userId=…#.svg]`, `[/relative.png]` and `[javascript:…#.png]` all arrive here as image
 * nodes. Only an absolute http(s) URL is something to fetch and draw.
 */
const isFetchableImage = (src: string): boolean => {
  try {
    const { protocol } = new URL(src)
    return protocol === 'http:' || protocol === 'https:'
  } catch {
    return false
  }
}

/**
 * A node is standalone when it's the line's own child (not nested inside
 * decoration markup) and the line has no other content besides whitespace.
 */
const isStandalone = (ancestors: readonly AnyNode[]): boolean => {
  const parent = ancestors[ancestors.length - 1]
  if (!parent || (parent.type !== 'line' && parent.type !== 'title')) return false
  return parent.children.filter((child) => !isWhitespaceText(child)).length === 1
}

export const computeImageTargets = (text: string): ImageTarget[] => {
  const page = parse(text, parseOptions())
  const out: ImageTarget[] = []

  visit(page, ['image', 'icon'], (node, ancestors) => {
    const { line, column } = node.position.start
    const standalone = isStandalone(ancestors)
    if (node.type === 'image') {
      const src = asImageSrc(node.src) ?? node.src
      if (isFetchableImage(src)) {
        out.push({ line, startChar: column, src, kind: 'image', standalone })
      }
    } else {
      out.push({
        line,
        startChar: column,
        src: node.user,
        kind: 'icon',
        iconUser: node.user,
        standalone,
      })
    }
  })

  return out
}
