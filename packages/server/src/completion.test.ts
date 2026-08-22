import { describe, expect, test } from 'bun:test'
import {
  detectCompletion,
  detectCompletionInDocument,
  filterAndSortTitles,
  normalizeForMatch,
} from './completion'

describe('detectCompletion — link', () => {
  test('unclosed [ mid-line', () => {
    const line = 'see [que'
    expect(detectCompletion(line, line.length)).toEqual({
      kind: 'link',
      query: 'que',
      replaceStart: 4,
      replaceEnd: 8,
    })
  })

  test('closed [done] -> null (cursor after the closing bracket)', () => {
    const line = 'see [done] already'
    expect(detectCompletion(line, 'see [done]'.length)).toBeNull()
  })

  test('cursor before the closing ] still triggers (only backward scan matters)', () => {
    // "[do|ne]" — no ] appears between the opening [ and the cursor, so this is a live query.
    const line = '[done] more'
    expect(detectCompletion(line, 3)).toEqual({
      kind: 'link',
      query: 'do',
      replaceStart: 0,
      replaceEnd: 3,
    })
  })

  test('`]` right after cursor extends the replace range through it', () => {
    const line = '[foo]'
    // cursor between 'foo' and the closing bracket: "[foo|]"
    const result = detectCompletion(line, 4)
    expect(result).toEqual({ kind: 'link', query: 'foo', replaceStart: 0, replaceEnd: 5 })
  })

  test('no following ] leaves replaceEnd at the cursor', () => {
    const line = '[foo'
    expect(detectCompletion(line, 4)).toEqual({
      kind: 'link',
      query: 'foo',
      replaceStart: 0,
      replaceEnd: 4,
    })
  })

  test('[[ is not a link trigger (bold/large-image syntax)', () => {
    const line = '[[foo'
    expect(detectCompletion(line, line.length)).toBeNull()
  })
})

describe('detectCompletion — hashtag', () => {
  test('#tag touching the cursor', () => {
    const line = 'see #tag'
    expect(detectCompletion(line, line.length)).toEqual({
      kind: 'hashtag',
      query: 'tag',
      replaceStart: 4,
      replaceEnd: 8,
    })
  })

  test('just typed # has an empty query', () => {
    const line = '#'
    expect(detectCompletion(line, 1)).toEqual({
      kind: 'hashtag',
      query: '',
      replaceStart: 0,
      replaceEnd: 1,
    })
  })

  test('# mid-word is not a tag boundary -> null', () => {
    const line = 'foo#bar'
    expect(detectCompletion(line, line.length)).toBeNull()
  })

  test('no # in the run at all -> null', () => {
    const line = 'just plain text'
    expect(detectCompletion(line, line.length)).toBeNull()
  })
})

describe('detectCompletionInDocument (AST-aware suppression)', () => {
  test('cursor inside inlineCode -> null', () => {
    const text = 'Title\nfoo `[que` bar'
    // cursor right after "que", inside the backticks
    const line = text.split('\n')[1] as string
    const character = line.indexOf('que') + 3
    expect(detectCompletionInDocument(text, { line: 1, character })).toBeNull()
  })

  test('cursor inside a code block -> null', () => {
    const lines = ['Title', 'code:foo.js', '  const x = [que']
    const text = lines.join('\n')
    expect(
      detectCompletionInDocument(text, { line: 2, character: (lines[2] as string).length }),
    ).toBeNull()
  })

  test('cursor outside code contexts still detects normally', () => {
    const lines = ['Title', 'see [que']
    const text = lines.join('\n')
    const character = (lines[1] as string).length
    expect(detectCompletionInDocument(text, { line: 1, character })).toEqual({
      kind: 'link',
      query: 'que',
      replaceStart: 4,
      replaceEnd: character,
    })
  })
})

describe('normalizeForMatch', () => {
  test('lowercases and NFKC-normalizes', () => {
    expect(normalizeForMatch('HELLO')).toBe('hello')
  })

  test('treats space and underscore as equal', () => {
    expect(normalizeForMatch('foo_bar')).toBe(normalizeForMatch('foo bar'))
  })

  test('handles Japanese text (NFKC folds full-width forms)', () => {
    expect(normalizeForMatch('ＡＢＣ')).toBe(normalizeForMatch('ABC'))
    expect(normalizeForMatch('日本語')).toBe('日本語')
  })
})

describe('filterAndSortTitles', () => {
  // 'pineapple' contains 'app' but does not start with it, and sits ahead of the startsWith
  // matches here on purpose — proves the bucket sort actually reorders, not just filters.
  const titles = [
    { title: 'Zebra' },
    { title: 'pineapple' },
    { title: 'apple pie' },
    { title: 'Application' },
    { title: 'banana' },
    { title: 'app_store' },
  ]

  test('substring matches, startsWith bucket first, stable within buckets', () => {
    const result = filterAndSortTitles(titles, 'app')
    expect(result.map((t) => t.title)).toEqual([
      'apple pie',
      'Application',
      'app_store',
      'pineapple',
    ])
  })

  test('space/underscore equivalence applies to the query too', () => {
    const result = filterAndSortTitles(titles, 'app_store')
    expect(result.map((t) => t.title)).toEqual(['app_store'])
  })

  test('hashtag mode excludes titles containing spaces', () => {
    const result = filterAndSortTitles(titles, 'app', { noSpaces: true })
    expect(result.map((t) => t.title)).toEqual(['Application', 'app_store', 'pineapple'])
  })

  test('caps results at 50', () => {
    const many = Array.from({ length: 80 }, (_, i) => ({ title: `item${i}` }))
    expect(filterAndSortTitles(many, 'item')).toHaveLength(50)
  })

  test('empty query returns everything (capped), preserving order', () => {
    const result = filterAndSortTitles(titles, '')
    expect(result.map((t) => t.title)).toEqual(titles.map((t) => t.title))
  })
})
