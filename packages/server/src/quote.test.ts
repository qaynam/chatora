import { describe, expect, test } from 'bun:test'
import { computeQuoteRanges } from './quote'

describe('computeQuoteRanges', () => {
  test('covers the marker and the space after it, leaving the text to start at endChar', () => {
    expect(computeQuoteRanges('Title\n> quoted text')).toEqual([
      { line: 1, startChar: 0, endChar: 2 },
    ])
  })

  test('a marker with no space still ends where the text begins', () => {
    expect(computeQuoteRanges('Title\n>quoted')).toEqual([{ line: 1, startChar: 0, endChar: 1 }])
  })

  test('startChar is the indent, so an indented quote lines up under its list item', () => {
    expect(computeQuoteRanges('Title\n  > quoted')).toEqual([{ line: 1, startChar: 2, endChar: 4 }])
  })

  test('consecutive quoted lines each get a range, so the bar reads as one column', () => {
    expect(computeQuoteRanges('Title\n> one\n> two\nplain')).toEqual([
      { line: 1, startChar: 0, endChar: 2 },
      { line: 2, startChar: 0, endChar: 2 },
    ])
  })

  test('a `>` inside a code block is code, not a quote', () => {
    expect(computeQuoteRanges('Title\ncode:sh\n > not a quote')).toEqual([])
  })

  test('a page with nothing quoted produces no ranges', () => {
    expect(computeQuoteRanges('Title\nplain [Link] text')).toEqual([])
  })
})
