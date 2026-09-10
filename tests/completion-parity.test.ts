// Which bracket completion answers in is decided twice: the server refuses everything but a
// plain link (isLinkBracket in packages/server/src/completion.ts), and the client re-opens the
// menu on the same rule (link_range in lua/chatora/completion.lua). If the two drift apart the
// client re-opens a menu the server will not fill, which is the flicker both rules exist to
// stop — so the same cases are run through both here.
import { describe, expect, test } from 'bun:test'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { detectCompletion } from '../packages/server/src/completion'
import { type NotationSpec, setNotations } from '../packages/server/src/notations'

const ROOT = join(import.meta.dir, '..')

/** The line is `before + after`, with the cursor between them. */
type Case = readonly [before: string, after: string]

interface Group {
  /** As `setup()` takes them, keyed by marker; the server gets the same set as specs. */
  readonly notations: Record<string, { name: string }>
  readonly cases: readonly Case[]
}

const GROUPS: readonly Group[] = [
  {
    notations: {},
    cases: [
      // The pair Cosense closes for you, and typing on inside it.
      ['[', ']'],
      ['[fo', 'o]'],
      ['see [que', ']'],
      ['[sakura プロモ', 'ーション]'],
      // Decorations: the marker alone, the space after it, and a body of any length.
      ['[*', ']'],
      ['[* ', ']'],
      ['[* 見出', 'し]'],
      ['[', '* 見出し]'],
      ['[*　', '全角スペース]'],
      ['[! ', '重要]'],
      ['[| 見', '出し]'],
      ['[-', ' 打ち消し]'],
      ['[-foo', ']'],
      // A link nested in a decoration is still a link.
      ['[* [', ']]'],
      ['[* 見出し [リン', 'ク]]'],
      ['[* 見出し ', '[リンク]]'],
      // Other notations.
      ['[$ x^', '2]'],
      ['[taro.ico', 'n]'],
      ['[taro.icon*', '5]'],
      ['[https://exa', 'mple.com/a]'],
      ['[ラベル https://exa', 'mple.com/a]'],
      ['[foo.pn', 'g]'],
      ['[/my-project/pa', 'ge]'],
      // Pairs that are not pairs.
      ['[[fo', 'o]]'],
      ['[unclosed', ''],
      ['[foo]', ' bar'],
      ['[ab', ' [cd]'],
      ['', '[foo]'],
      ['plain text', ''],
      // The client has no hashtag rule at all: the server answers, the menu is not re-opened.
      ['see #ta', 'g'],
    ],
  },
  {
    notations: { '@': { name: 'note' } },
    cases: [
      ['[@ メ', 'モ]'],
      ['[@メ', 'モ]'],
    ],
  },
]

const specsOf = (group: Group): NotationSpec[] =>
  Object.entries(group.notations).map(([marker, spec]) => ({ marker, name: spec.name }))

const FLAT = GROUPS.flatMap((group) =>
  group.cases.map((c) => ({ before: c[0], after: c[1], specs: specsOf(group) })),
)

const LUA = `
vim.opt.runtimepath:prepend(${JSON.stringify(ROOT)})
local completion = require('chatora.completion')
local config = require('chatora.config')
local groups = vim.json.decode(table.concat(vim.fn.readfile(arg[1]), '\\n'))
local out = {}
for _, group in ipairs(groups) do
  config.setup({ notations = group.notations })
  for _, case in ipairs(group.cases) do
    local before = case[1]
    local open, close = completion.link_range(before .. case[2], #before)
    out[#out + 1] = { open = open or vim.NIL, close = close or vim.NIL }
  end
end
vim.fn.writefile({ vim.json.encode(out) }, arg[2])
`

interface LuaRange {
  open: number | null
  close: number | null
}

const runLua = (): LuaRange[] => {
  const dir = mkdtempSync(join(tmpdir(), 'chatora-completion-'))
  try {
    const script = join(dir, 'parity.lua')
    const input = join(dir, 'cases.json')
    const output = join(dir, 'out.json')
    writeFileSync(script, LUA)
    writeFileSync(input, JSON.stringify(GROUPS))
    const run = Bun.spawnSync(['nvim', '--clean', '-l', script, input, output])
    if (run.exitCode !== 0) throw new Error(`nvim failed: ${run.stderr.toString()}`)
    return JSON.parse(readFileSync(output, 'utf8'))
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

/** The Lua side counts bytes and starts at 1; the server counts UTF-16 units and starts at 0. */
const asLuaRange = (line: string, start: number, end: number): LuaRange => ({
  open: Buffer.byteLength(line.slice(0, start), 'utf8') + 1,
  close: Buffer.byteLength(line.slice(0, end), 'utf8'),
})

describe('completion trigger parity between completion.lua and completion.ts', () => {
  const lua = runLua()

  test.each(FLAT.map((c, i) => [`${c.before}|${c.after}`, i] as const))('%s', (_label, i) => {
    const c = FLAT[i] as (typeof FLAT)[number]
    const line = c.before + c.after
    setNotations(c.specs)
    try {
      const detection = detectCompletion(line, c.before.length)
      // Hashtags are the server's alone: the client only ever re-opens inside a bracket.
      const link = detection?.kind === 'link' ? detection : null
      expect(lua[i]).toEqual(
        link === null
          ? { open: null, close: null }
          : asLuaRange(line, link.replaceStart, link.replaceEnd),
      )
    } finally {
      setNotations([])
    }
  })
})
