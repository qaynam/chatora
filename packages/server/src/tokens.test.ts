import { afterEach, describe, expect, test } from 'bun:test'
import { setNotations } from './notations'
import { computeTokens, encodeTokens, type RawToken, TOKEN_TYPES } from './tokens'

const findAll = (tokens: RawToken[], type: RawToken['type']) =>
  tokens.filter((t) => t.type === type)

describe('computeTokens', () => {
  test('title line becomes a single title token spanning the whole line', () => {
    const src = 'My Title\nsome body text'
    const tokens = computeTokens(src)
    const titles = findAll(tokens, 'title')
    expect(titles).toEqual([{ line: 0, char: 0, length: 'My Title'.length, type: 'title' }])
  })

  test('internalLink and hashtag positions', () => {
    const src = 'Title\n[Link Text] and #hashtag here'
    const line = src.split('\n')[1] as string
    const tokens = computeTokens(src)

    const linkStart = line.indexOf('[Link Text]')
    const linkEnd = linkStart + '[Link Text]'.length
    expect(findAll(tokens, 'link')).toEqual([
      { line: 1, char: linkStart, length: linkEnd - linkStart, type: 'link' },
    ])

    const tagStart = line.indexOf('#hashtag')
    expect(findAll(tokens, 'hashtag')).toEqual([
      { line: 1, char: tagStart, length: '#hashtag'.length, type: 'hashtag' },
    ])
  })

  test('inlineCode position', () => {
    const src = 'Title\nfoo `code span` bar'
    const line = src.split('\n')[1] as string
    const tokens = computeTokens(src)
    const start = line.indexOf('`code span`')
    expect(findAll(tokens, 'code')).toEqual([
      { line: 1, char: start, length: '`code span`'.length, type: 'code' },
    ])
  })

  test('UTF-16 column sanity check with a Japanese line containing a link', () => {
    const src = 'Title\n日本語[リンク]あと'
    const line = src.split('\n')[1] as string
    const tokens = computeTokens(src)

    const start = line.indexOf('[リンク]')
    const end = start + '[リンク]'.length
    expect(findAll(tokens, 'link')).toEqual([
      { line: 1, char: start, length: end - start, type: 'link' },
    ])
  })

  test('multi-line code block is split into one token per physical line, header included', () => {
    const src = ['Title', 'code:foo.js', '  const a = 1', '  const b = 2', 'after'].join('\n')
    const lines = src.split('\n')
    const tokens = computeTokens(src)
    const codeBlocks = findAll(tokens, 'codeBlock')

    expect(codeBlocks).toEqual([
      { line: 1, char: 0, length: (lines[1] as string).length, type: 'codeBlock' },
      { line: 2, char: 0, length: (lines[2] as string).length, type: 'codeBlock' },
      { line: 3, char: 0, length: (lines[3] as string).length, type: 'codeBlock' },
    ])
    // The dedented line following the block must not be swept in.
    expect(codeBlocks.some((t) => t.line === 4)).toBe(false)
  })

  test('table block is split into one token per physical line, header included', () => {
    const src = ['Title', 'table:t', '  a\tb', '  c\td', 'after'].join('\n')
    const lines = src.split('\n')
    const tokens = computeTokens(src)
    const tables = findAll(tokens, 'table')
    expect(tables.map((t) => t.line)).toEqual([1, 2, 3])
    expect(tables[0]).toEqual({
      line: 1,
      char: 0,
      length: (lines[1] as string).length,
      type: 'table',
    })
  })

  test('bold emphasis levels: * -> bold, ** -> bold2, *** and up -> bold3', () => {
    expect(findAll(computeTokens('Title\n[* one]'), 'bold')).toHaveLength(1)
    expect(findAll(computeTokens('Title\n[** two]'), 'bold2')).toHaveLength(1)
    expect(findAll(computeTokens('Title\n[*** three]'), 'bold3')).toHaveLength(1)
    expect(findAll(computeTokens('Title\n[***** five]'), 'bold3')).toHaveLength(1)
  })

  test('decoration priority: bold > italic > strike > underline, no separate child tokens', () => {
    const bold = computeTokens('Title\n[* bold text]')
    expect(findAll(bold, 'bold')).toHaveLength(1)
    expect(findAll(bold, 'italic')).toHaveLength(0)

    // strike + italic combined -> italic wins (bold > italic > strike > underline).
    const combo = computeTokens('Title\n[-/ strike and italic]')
    expect(findAll(combo, 'italic')).toHaveLength(1)
    expect(findAll(combo, 'strike')).toHaveLength(0)
    expect(findAll(combo, 'bold')).toHaveLength(0)

    const underline = computeTokens('Title\n[_ underlined]')
    expect(findAll(underline, 'underline')).toHaveLength(1)
  })

  test('a link nested in a decoration keeps its own token, overlapping the decoration', () => {
    const src = 'Title\n[* bold with [Nested] link]'
    const line = src.split('\n')[1] as string
    const tokens = computeTokens(src)

    expect(findAll(tokens, 'bold')).toEqual([
      { line: 1, char: 0, length: line.length, type: 'bold' },
    ])
    expect(findAll(tokens, 'link')).toEqual([
      { line: 1, char: line.indexOf('[Nested]'), length: '[Nested]'.length, type: 'link' },
    ])
  })

  test('a decoration wrapping only a link still emits both', () => {
    const tokens = computeTokens('Title\n[* [nuclear]]')
    expect(findAll(tokens, 'bold')).toHaveLength(1)
    expect(findAll(tokens, 'link')).toHaveLength(1)
  })

  test('encodeTokens keeps the outer decoration ahead of the child it contains', () => {
    const src = 'Title\n[* [nuclear]]'
    const legend = [...TOKEN_TYPES]
    const data = encodeTokens(computeTokens(src))
    // The client sets marks in this order, so the child's color wins the overlap.
    const types: string[] = []
    for (let i = 0; i < data.length; i += 5) types.push(legend[data[i + 3] as number] as string)
    expect(types.slice(1)).toEqual(['bold', 'link'])
  })

  test('quote marker token covers only the leading `> ` marker, not the content', () => {
    const src = 'Title\n> quoted [Link] text'
    const line = src.split('\n')[1] as string
    const tokens = computeTokens(src)

    expect(findAll(tokens, 'quote')).toEqual([{ line: 1, char: 0, length: 2, type: 'quote' }])
    const linkStart = line.indexOf('[Link]')
    expect(findAll(tokens, 'link')).toEqual([
      { line: 1, char: linkStart, length: '[Link]'.length, type: 'link' },
    ])
  })

  test('quote line with no content after the marker emits no zero-length token', () => {
    const tokens = computeTokens('Title\n>')
    expect(findAll(tokens, 'quote')).toEqual([{ line: 1, char: 0, length: 1, type: 'quote' }])
  })

  const complexSource = [
    'My Page Title',
    '#intro this page is about [Cosense] and #testing',
    '> a quoted line with `inline code` and a [Link]',
    '[* bold] [/ italic] [- strike] [_ underline] [** [Nested] link]',
    'code:example.ts',
    '  const x = 1',
    '  const y = 2',
    'table:data',
    '  a\tb\tc',
    'plain text after everything',
  ].join('\n')

  // Two tokens on a line are either disjoint or properly nested — a decoration wrapping a
  // link overlaps it, but never partially. That is what lets the client set marks in
  // encodeTokens' order and get the inner token drawn on top of the outer one.
  test('invariant: same-line tokens are disjoint or nested, never partially overlapping', () => {
    const tokens = computeTokens(complexSource)
    const byLine = new Map<number, RawToken[]>()
    for (const t of tokens) {
      const list = byLine.get(t.line) ?? []
      list.push(t)
      byLine.set(t.line, list)
    }
    for (const list of byLine.values()) {
      const sorted = [...list].sort((a, b) => a.char - b.char || b.length - a.length)
      for (let i = 1; i < sorted.length; i++) {
        const prev = sorted[i - 1] as RawToken
        const cur = sorted[i] as RawToken
        const disjoint = cur.char >= prev.char + prev.length
        const nested = cur.char + cur.length <= prev.char + prev.length
        expect(disjoint || nested).toBe(true)
      }
    }
  })

  test('invariant: tokens are sorted by (line, char)', () => {
    const tokens = computeTokens(complexSource)
    for (let i = 1; i < tokens.length; i++) {
      const prev = tokens[i - 1] as RawToken
      const cur = tokens[i] as RawToken
      expect(cur.line > prev.line || (cur.line === prev.line && cur.char >= prev.char)).toBe(true)
    }
  })

  test('every token has positive length', () => {
    const tokens = computeTokens(complexSource)
    expect(tokens.every((t) => t.length > 0)).toBe(true)
  })
})

describe('computeTokens with custom notations', () => {
  afterEach(() => setNotations([]))

  test('a configured marker produces a token of its own name', () => {
    setNotations([{ marker: '|', name: 'highlight' }])
    const src = 'Title\n[| body text]'
    const line = src.split('\n')[1] as string
    const tokens = computeTokens(src)
    expect(findAll(tokens, 'highlight')).toEqual([
      { line: 1, char: 0, length: line.length, type: 'highlight' },
    ])
  })

  test('an unconfigured marker stays a plain internalLink, not a custom token', () => {
    setNotations([{ marker: '=', name: 'boxed' }])
    const tokens = computeTokens('Title\n[| body text]')
    expect(findAll(tokens, 'boxed')).toHaveLength(0)
    expect(findAll(tokens, 'link')).toHaveLength(1)
  })

  test('a run wearing several markers gets a token each, the first written one last', () => {
    setNotations([
      { marker: '!', name: 'important' },
      { marker: '{', name: 'balloon' },
    ])
    const src = 'Title\n[!{ body]'
    const line = (src.split('\n')[1] as string).length
    const spans = computeTokens(src).filter((t) => t.char === 0 && t.length === line)
    // Later token, later extmark, higher up: the marker written first wins a shared
    // attribute, and everything neither of them sets combines underneath.
    expect(spans.map((t) => t.type)).toEqual(['balloon', 'important'])
  })

  test('an official marker in the run keeps its token, underneath the notation', () => {
    setNotations([{ marker: '!', name: 'important' }])
    const src = 'Title\n[!* body]'
    const line = (src.split('\n')[1] as string).length
    const spans = computeTokens(src).filter((t) => t.char === 0 && t.length === line)
    expect(spans.map((t) => t.type)).toEqual(['bold', 'important'])
  })

  test('a decoration character with no notation behind it keeps the run tokenized', () => {
    setNotations([{ marker: '!', name: 'important' }])
    const tokens = computeTokens("Title\n[!' body]")
    expect(findAll(tokens, 'important')).toHaveLength(1)
    expect(findAll(tokens, 'link')).toHaveLength(0)
  })

  test('legend-index round trip: encodeTokens indexes a custom type past TOKEN_TYPES, in marker order', () => {
    setNotations([
      { marker: '|', name: 'highlight' },
      { marker: '=', name: 'boxed' },
    ])
    const legend = [...TOKEN_TYPES, 'boxed', 'highlight'] // marker-ascending: '=' < '|'
    const tokens = computeTokens('Title\n[| a] [= b]')
    const encoded = encodeTokens(tokens)

    const byType = new Map(tokens.map((t) => [t.type, t]))
    for (const [type, token] of byType) {
      // Re-derive this token's absolute index the same way decode would.
      let line = 0
      let char = 0
      let index = -1
      for (let i = 0; i < encoded.length; i += 5) {
        const deltaLine = encoded[i] as number
        const deltaChar = encoded[i + 1] as number
        line = deltaLine === 0 ? line : line + deltaLine
        char = deltaLine === 0 ? char + deltaChar : deltaChar
        if (line === token.line && char === token.char) {
          index = encoded[i + 3] as number
          break
        }
      }
      expect(index).toBe(legend.indexOf(type))
    }
  })
})

describe('encodeTokens', () => {
  const decode = (data: number[]): RawToken[] => {
    const out: RawToken[] = []
    let line = 0
    let char = 0
    for (let i = 0; i < data.length; i += 5) {
      const deltaLine = data[i] as number
      const deltaChar = data[i + 1] as number
      const length = data[i + 2] as number
      const typeIndex = data[i + 3] as number
      line = deltaLine === 0 ? line : line + deltaLine
      char = deltaLine === 0 ? char + deltaChar : deltaChar
      out.push({ line, char, length, type: TOKEN_TYPES[typeIndex] as RawToken['type'] })
    }
    return out
  }

  test('round-trips through decode', () => {
    const src = [
      'My Page Title',
      '#intro this page is about [Cosense] and #testing',
      '> a quoted line with `inline code` and a [Link]',
      '[* bold] [/ italic] [- strike] [_ underline] [** [Nested] link]',
    ].join('\n')
    const tokens = computeTokens(src)
    const encoded = encodeTokens(tokens)
    expect(encoded.length % 5).toBe(0)
    const decoded = decode(encoded)
    const sortedOriginal = [...tokens].sort((a, b) => a.line - b.line || a.char - b.char)
    expect(decoded).toEqual(sortedOriginal)
  })

  test('empty input encodes to an empty array', () => {
    expect(encodeTokens([])).toEqual([])
  })

  test('single token encodes as absolute line/char with zero deltas afterward', () => {
    const encoded = encodeTokens([{ line: 3, char: 5, length: 4, type: 'link' }])
    expect(encoded).toEqual([3, 5, 4, TOKEN_TYPES.indexOf('link'), 0])
  })
})
