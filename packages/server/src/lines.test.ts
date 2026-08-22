import { describe, expect, test } from 'bun:test'
import { textToLines } from './lines'

describe('textToLines', () => {
  test('strips exactly one trailing newline', () => {
    expect(textToLines('a\nb\nc\n')).toEqual(['a', 'b', 'c'])
  })

  test('does not strip when there is no trailing newline', () => {
    expect(textToLines('a\nb\nc')).toEqual(['a', 'b', 'c'])
  })

  test('does not collapse multiple trailing newlines', () => {
    expect(textToLines('a\nb\n\n')).toEqual(['a', 'b', ''])
  })

  test('single empty line stays a single empty line', () => {
    expect(textToLines('')).toEqual([''])
  })

  test('a lone trailing newline becomes one empty line', () => {
    expect(textToLines('\n')).toEqual([''])
  })

  test('title-only page with trailing newline', () => {
    expect(textToLines('My Title\n')).toEqual(['My Title'])
  })
})
