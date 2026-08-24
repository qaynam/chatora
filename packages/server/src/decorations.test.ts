import { afterEach, describe, expect, test } from 'bun:test'
import { computeConcealRanges } from './decorations'
import { setNotations } from './notations'

const rangesOnLine = (text: string, line: number) =>
  computeConcealRanges(text).filter((r) => r.line === line)

describe('computeConcealRanges', () => {
  test('decoration: hides the marker prefix and closing bracket', () => {
    // line 1 (0-based): '[* 太字]' — '[* ' is cols 0..3, ']' is the last col.
    const text = 'タイトル\n[* 太字]'
    expect(rangesOnLine(text, 1)).toEqual([
      { line: 1, startChar: 0, endChar: 3 },
      { line: 1, startChar: 5, endChar: 6 },
    ])
  })

  test('internal link: hides only the brackets', () => {
    const text = 'タイトル\nsee [ページ名] here'
    const ranges = rangesOnLine(text, 1)
    expect(ranges).toEqual([
      { line: 1, startChar: 4, endChar: 5 },
      { line: 1, startChar: 9, endChar: 10 },
    ])
  })

  test('bare URL: nothing to conceal', () => {
    const text = 'タイトル\nhttps://example.com/x'
    expect(rangesOnLine(text, 1)).toEqual([])
  })

  test('bracketed external link conceals its brackets', () => {
    const text = 'タイトル\n[https://example.com/x]'
    const ranges = rangesOnLine(text, 1)
    expect(ranges.length).toBe(2)
    expect(ranges[0]).toEqual({ line: 1, startChar: 0, endChar: 1 })
  })

  test('inline code hides the backticks', () => {
    const text = 'タイトル\na `code` b'
    expect(rangesOnLine(text, 1)).toEqual([
      { line: 1, startChar: 2, endChar: 3 },
      { line: 1, startChar: 7, endChar: 8 },
    ])
  })

  test('code block interiors produce no conceal ranges', () => {
    const text = 'タイトル\ncode:x.ts\n const a = [1]'
    expect(computeConcealRanges(text).filter((r) => r.line >= 1)).toEqual([])
  })

  test('hashtags stay visible', () => {
    const text = 'タイトル\n#tag のまま'
    expect(rangesOnLine(text, 1)).toEqual([])
  })
})

describe('custom notations', () => {
  afterEach(() => setNotations([]))

  test('a configured marker hides `[| ` and `]` the same way as an official decoration', () => {
    setNotations([{ marker: '|', name: 'highlight' }])
    const text = 'タイトル\n[| 太字]'
    expect(rangesOnLine(text, 1)).toEqual([
      { line: 1, startChar: 0, endChar: 3 },
      { line: 1, startChar: 5, endChar: 6 },
    ])
  })
})

/** What the editor shows for `line`: the raw text minus every concealed range. */
const rendered = (text: string, line: number): string => {
  const source = text.split('\n')[line] ?? ''
  const hidden = new Set<number>()
  for (const r of rangesOnLine(text, line)) {
    for (let i = r.startChar; i < r.endChar; i++) hidden.add(i)
  }
  return [...source].filter((_, i) => !hidden.has(i)).join('')
}

describe('external links render as their label', () => {
  const URL = 'https://note.com/sakura/n/n0123456789ab'

  test('[label url]: the URL and its separating space are hidden', () => {
    const label = 'note: 長いラベルでも折り返さずにそのまま見せる'
    const text = `タイトル\n[${label} ${URL}]`
    expect(rendered(text, 1)).toBe(label)
  })

  test('[url label]: same, with the URL leading', () => {
    const text = `タイトル\n[${URL} sakura note]`
    expect(rendered(text, 1)).toBe('sakura note')
  })

  test('[url]: kept verbatim — hiding it would leave nothing to click', () => {
    const text = `タイトル\n[${URL}]`
    expect(rendered(text, 1)).toBe(URL)
  })

  test('a bare URL is untouched', () => {
    const text = `タイトル\nsee ${URL} for more`
    expect(rangesOnLine(text, 1)).toEqual([])
  })

  test('surrounding text survives', () => {
    const text = `タイトル\nsee [ラベル ${URL}] here`
    expect(rendered(text, 1)).toBe('see ラベル here')
  })
})
