import { describe, expect, test } from 'bun:test'
import { computeInternalLinks, titleKey } from './links'

describe('computeInternalLinks', () => {
  test('finds bracketed links and hashtags, and nothing else', () => {
    const text = [
      'タイトル',
      '[ページA] と #タグ',
      '[/other/よそ] と [https://example.com 外部] は対象外',
      '`[コード内]` も対象外',
    ].join('\n')
    expect(computeInternalLinks(text).map((l) => l.title)).toEqual(['ページA', 'タグ'])
  })

  test('columns cover the whole notation', () => {
    const [link] = computeInternalLinks('T\n[ページ]')
    expect(link).toMatchObject({ line: 1, startChar: 0, endChar: 5 })
  })
})

describe('titleKey', () => {
  // Cosense keys its own index by titleLc, which lowercases *and* writes spaces as
  // underscores; both forms reach the same page, so both have to fold together here or a
  // link with a space in it reads as a page that was never written.
  test('folds case and spaces the way Cosense does', () => {
    expect(titleKey('Side Kanban')).toBe(titleKey('side_kanban'))
    expect(titleKey('MOOCONN-WEB')).toBe(titleKey('mooconn-web'))
  })

  test('leaves everything else alone', () => {
    expect(titleKey('第1話：なあに？')).toBe('第1話：なあに？')
  })
})
