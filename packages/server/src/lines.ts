/**
 * savePage line handling. Neovim always writes a buffer with a trailing EOL, so the document
 * text nvim hands us has one trailing '\n' that is not itself a blank line — strip exactly one
 * before splitting, otherwise every save would invent a spurious trailing empty line.
 */
export const textToLines = (text: string): string[] => {
  const trimmed = text.endsWith('\n') ? text.slice(0, -1) : text
  return trimmed.split('\n')
}
