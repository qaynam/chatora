import { describe, expect, test } from 'bun:test'
import { Asearch } from './asearch'

// Cases ported from cosense-app-client/packages/domain/src/asearch.test.ts, plus a few
// extra 2-error / miss cases per this port's own requirements.

describe('Asearch — anchored approximate match', () => {
  test('0 errors requires an exact match', () => {
    const m = Asearch('abc')
    expect(m('abc', 0)).toBe(true)
    expect(m('abd', 0)).toBe(false)
  })

  test('anchored: extra surrounding text does not match even with slack', () => {
    const m = Asearch('abc')
    expect(m('xxabcyy', 3)).toBe(false)
  })

  test('1 error tolerates a single substitution', () => {
    const m = Asearch('abcd')
    expect(m('abXd', 0)).toBe(false)
    expect(m('abXd', 1)).toBe(true)
  })

  test('1 error tolerates a single insertion or deletion', () => {
    const m = Asearch('abcd')
    expect(m('abcXd', 1)).toBe(true) // inserted X
    expect(m('acd', 1)).toBe(true) // deleted b
  })

  test('2 errors tolerate two edits but not one alone at ambig=1', () => {
    const m = Asearch('abcd')
    expect(m('aXXd', 1)).toBe(false)
    expect(m('aXXd', 2)).toBe(true)
  })

  test('too many errors still miss at ambig=2', () => {
    const m = Asearch('abcd')
    expect(m('XXXX', 2)).toBe(false)
  })

  test('ASCII is case-insensitive', () => {
    const m = Asearch('abc')
    expect(m('ABC', 0)).toBe(true)
  })

  test('Japanese text: exact match and 1-error typo tolerance', () => {
    const m = Asearch('検索')
    expect(m('検索', 0)).toBe(true)
    expect(m('検素', 1)).toBe(true) // one character differs
    expect(m('検素', 0)).toBe(false)
  })

  test('Japanese text: an unrelated longer string misses even at 2 errors', () => {
    const m = Asearch('検索エンジン')
    expect(m('全然違う文字列', 2)).toBe(false)
  })

  test('halfwidth space in the pattern is epsilon (matches anything there)', () => {
    const m = Asearch('a b')
    expect(m('axb', 0)).toBe(true)
    expect(m('ab', 0)).toBe(true)
  })
})
