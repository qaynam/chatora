/**
 * Internal `cosense://<project>/<title>` URI scheme shared with the Lua client
 * (nvim/lua/chatora/uri.lua). The URI doubles as the Neovim buffer name, which the user sees
 * in tablines/statuslines — so unicode (Japanese titles) stays raw and only characters that
 * would break the URI structure (`%`, `/`, `?`, `#`, controls) are percent-encoded. Both
 * sides must produce byte-identical URIs for the same title. This is unrelated to
 * CosenseApi's own HTTP path encoding (encodeTitleForUrl), which callers never see: pass raw
 * titles into CosenseApi and build cosense:// URIs with this module only.
 */

const URI_PATTERN = /^cosense:\/\/([^/]+)\/(.*)$/

// %, /, ?, # plus control chars (matching Lua's %c class: 0x00-0x1F and 0x7F).
// biome-ignore lint/suspicious/noControlCharactersInRegex: control chars must be encoded
const ENCODE_PATTERN = /[%/?#\u0000-\u001f\u007f]/g

export interface ParsedUri {
  readonly project: string
  readonly title: string
}

const encodeTitleForUri = (title: string): string =>
  title.replace(
    ENCODE_PATTERN,
    (c) => `%${c.charCodeAt(0).toString(16).toUpperCase().padStart(2, '0')}`,
  )

export const formatUri = (project: string, title: string): string =>
  `cosense://${project}/${encodeTitleForUri(title)}`

export const parseUri = (uri: string): ParsedUri | null => {
  const match = URI_PATTERN.exec(uri)
  if (!match) return null
  const project = match[1]
  const encodedTitle = match[2]
  if (project === undefined || encodedTitle === undefined || project === '') return null
  try {
    // decodeURIComponent handles our %XX escapes and passes raw unicode through unchanged;
    // it also still accepts fully-encoded URIs (e.g. hand-typed or from older buffers).
    return { project, title: decodeURIComponent(encodedTitle) }
  } catch {
    return null
  }
}
