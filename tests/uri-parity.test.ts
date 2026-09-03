// The cosense:// URI is built on both sides of the LSP boundary: lua/chatora/uri.lua names
// the buffer with it, packages/server/src/uriScheme.ts keys the server's page state by it,
// and a page is found only if the two agree byte for byte. Neither side can see the other,
// so the Lua rule is run in a headless Neovim and compared here.
import { describe, expect, test } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { formatUri, parseUri } from '../packages/server/src/uriScheme'

const ROOT = join(import.meta.dir, '..')
const PROJECT = 'my-project'
const TITLES = [
  'Hello World',
  '日本語のタイトル',
  'C#入門',
  'a/b',
  '100%',
  'why?',
  'next.js',
  'tab\there',
  'ctrl\u0001char',
  'del\u007fchar',
  'all %/?# at once',
]

const LUA = `
vim.opt.runtimepath:prepend(${JSON.stringify(ROOT)})
local uri = require('chatora.uri')
local titles = vim.json.decode(table.concat(vim.fn.readfile(arg[1]), '\\n'))
local out = {}
for _, title in ipairs(titles) do
  local formatted = uri.format(${JSON.stringify(PROJECT)}, title)
  local project, parsed = uri.parse(formatted)
  out[#out + 1] = { formatted = formatted, project = project, title = parsed }
end
vim.fn.writefile({ vim.json.encode(out) }, arg[2])
`

const runLua = (): { formatted: string; project: string; title: string }[] => {
  const dir = mkdtempSync(join(tmpdir(), 'chatora-uri-'))
  try {
    const script = join(dir, 'parity.lua')
    const input = join(dir, 'titles.json')
    const output = join(dir, 'out.json')
    writeFileSync(script, LUA)
    writeFileSync(input, JSON.stringify(TITLES))
    const run = Bun.spawnSync(['nvim', '--clean', '-l', script, input, output])
    if (run.exitCode !== 0) throw new Error(`nvim failed: ${run.stderr.toString()}`)
    return JSON.parse(readFileSync(output, 'utf8'))
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

describe('cosense:// URI parity between uri.lua and uriScheme.ts', () => {
  const lua = runLua()

  test.each(TITLES.map((title, i) => [title, i] as const))('%j', (title, i) => {
    const fromLua = lua[i]
    expect(fromLua.formatted).toBe(formatUri(PROJECT, title))
    expect({ project: fromLua.project, title: fromLua.title }).toEqual({ project: PROJECT, title })
    expect(parseUri(fromLua.formatted)).toEqual({ project: PROJECT, title })
  })
})
