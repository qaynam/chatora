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
  /** End of the notation, so a client can tell a backend the image's whole span. */
  readonly endChar: number
  /** For `kind: 'icon'` this is the raw icon user (same value as `iconUser`), not a URL — the caller builds the icon URL itself. */
  readonly src: string
  readonly kind: 'image' | 'icon'
  readonly iconUser?: string
  /** True when the node is the only non-whitespace child of its line (or the title line). */
  readonly standalone: boolean
  /** `[[url]]` — Cosense's large form. Never set on an icon. */
  readonly large: boolean
  /**
   * True when every non-whitespace child of the line is drawable. Such a line is a
   * gallery — something to look at — rather than prose that happens to contain a
   * picture, and the client sizes it accordingly.
   */
  readonly gallery: boolean
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

const DRAWABLE: ReadonlySet<string> = new Set(['image', 'icon'])

/**
 * The line's own content, ignoring whitespace — empty when the node is nested inside
 * decoration markup rather than sitting directly on the line.
 */
const lineContent = (ancestors: readonly AnyNode[]): readonly AnyNode[] => {
  const parent = ancestors[ancestors.length - 1]
  if (!parent || (parent.type !== 'line' && parent.type !== 'title')) return []
  return parent.children.filter((child) => !isWhitespaceText(child))
}

export const computeImageTargets = (text: string): ImageTarget[] => {
  const page = parse(text, parseOptions())
  const out: ImageTarget[] = []

  visit(page, ['image', 'icon'], (node, ancestors) => {
    const { line, column } = node.position.start
    const endChar = node.position.end.column
    const content = lineContent(ancestors)
    const standalone = content.length === 1
    // An icon among images still makes a gallery: `[a.icon] [b.icon]` is a row of
    // pictures, not a sentence.
    const gallery = content.length > 0 && content.every((child) => DRAWABLE.has(child.type))
    if (node.type === 'image') {
      const src = asImageSrc(node.src) ?? node.src
      if (isFetchableImage(src)) {
        out.push({
          line,
          startChar: column,
          endChar,
          src,
          kind: 'image',
          standalone,
          gallery,
          large: node.large === true,
        })
      }
    } else {
      out.push({
        line,
        startChar: column,
        endChar,
        src: node.user,
        kind: 'icon',
        iconUser: node.user,
        standalone,
        gallery,
        large: false,
      })
    }
  })

  return out
}
