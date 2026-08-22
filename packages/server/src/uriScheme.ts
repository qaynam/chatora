/**
 * Internal `cosense://<project>/<encodeURIComponent(title)>` URI scheme shared with the Lua
 * client (nvim/lua/chatora/uri.lua). Percent-encoding is plain encodeURIComponent — this is
 * unrelated to CosenseApi's own HTTP path encoding (encodeTitleForUrl), which callers never
 * see: pass raw titles into CosenseApi and build cosense:// URIs with this module only.
 */

const URI_PATTERN = /^cosense:\/\/([^/]+)\/(.*)$/

export interface ParsedUri {
  readonly project: string
  readonly title: string
}

export const formatUri = (project: string, title: string): string =>
  `cosense://${project}/${encodeURIComponent(title)}`

export const parseUri = (uri: string): ParsedUri | null => {
  const match = URI_PATTERN.exec(uri)
  if (!match) return null
  const project = match[1]
  const encodedTitle = match[2]
  if (project === undefined || encodedTitle === undefined || project === '') return null
  try {
    return { project, title: decodeURIComponent(encodedTitle) }
  } catch {
    return null
  }
}
