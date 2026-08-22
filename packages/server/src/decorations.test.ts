import { describe, expect, test } from 'bun:test'
import { computeConcealRanges } from './decorations'

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
