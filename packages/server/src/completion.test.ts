import { describe, expect, test } from 'bun:test'
import { CompletionItemKind } from 'vscode-languageserver/node'
import {
  buildCandidateIndex,
  type Candidate,
  candidateItemFields,
  detectCompletion,
  detectCompletionInDocument,
  normalizeForMatch,
  rankCandidates,
  type TitleEntryLike,
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

describe('rankCandidates', () => {
  const c = (title: string, opts: Partial<Candidate> = {}): Candidate => ({
    title,
    key: normalizeForMatch(title),
    exists: true,
    updated: undefined,
    ...opts,
  })

  // 'pineapple' contains 'app' but does not start with it, and sits ahead of the startsWith
  // matches here on purpose — proves the tiering actually reorders, not just filters.
  const titles = [
    c('Zebra'),
    c('pineapple'),
    c('apple pie'),
    c('Application'),
    c('banana'),
    c('app_store'),
  ]

  test('substring matches, startsWith tier first, stable within tiers', () => {
    const result = rankCandidates(titles, 'app')
    expect(result.map((t) => t.title)).toEqual([
      'apple pie',
      'Application',
      'app_store',
      'pineapple',
    ])
  })

  test('space/underscore equivalence applies to the query too', () => {
    const result = rankCandidates(titles, 'app_store')
    expect(result.map((t) => t.title)).toEqual(['app_store'])
  })

  test('hashtag mode excludes titles containing spaces', () => {
    const result = rankCandidates(titles, 'app', { noSpaces: true })
    expect(result.map((t) => t.title)).toEqual(['Application', 'app_store', 'pineapple'])
  })

  test('caps results at 50', () => {
    const many = Array.from({ length: 80 }, (_, i) => c(`item${i}`))
    expect(rankCandidates(many, 'item')).toHaveLength(50)
  })

  test('empty query returns everything (capped), preserving API order when no updated data', () => {
    const result = rankCandidates(titles, '')
    expect(result.map((t) => t.title)).toEqual(titles.map((t) => t.title))
  })

  test('empty query sorts by updated desc when the pool has updated data', () => {
    const withDates = [
      c('old', { updated: 100 }),
      c('new', { updated: 300 }),
      c('mid', { updated: 200 }),
    ]
    expect(rankCandidates(withDates, '').map((t) => t.title)).toEqual(['new', 'mid', 'old'])
  })

  test('tiers: exact beats prefix beats substring beats fuzzy', () => {
    // 'apq' does not start with or contain 'app' — it only surfaces via Asearch fuzzy
    // matching (1-char substitution against the whole query, verified empirically).
    const candidates = [c('pineapple'), c('apq'), c('App Store'), c('app')]
    const result = rankCandidates(candidates, 'app')
    expect(result.map((t) => t.title)).toEqual(['app', 'App Store', 'pineapple', 'apq'])
  })

  test('fuzzy tier: 1-error matches rank before 2-error-only matches', () => {
    // 'apq' matches Asearch('app') at ambig=1; 'apxy' only at ambig=2 (verified empirically).
    // Neither is a prefix or substring match, so both only surface via the fuzzy tier.
    const candidates = [c('apxy'), c('apq')]
    const result = rankCandidates(candidates, 'app')
    expect(result.map((t) => t.title)).toEqual(['apq', 'apxy'])
  })

  test('fuzzy tier: candidates beyond 2 errors are excluded entirely', () => {
    const candidates = [c('app'), c('xyz')]
    const result = rankCandidates(candidates, 'app')
    expect(result.map((t) => t.title)).toEqual(['app'])
  })

  test('fuzzy tiers are skipped once the stricter tiers already fill the cap', () => {
    const substringFill = Array.from({ length: 50 }, (_, i) => c(`xapp${i}`))
    const fuzzyOnly = c('apq')
    const result = rankCandidates([...substringFill, fuzzyOnly], 'app')
    expect(result).toHaveLength(50)
    expect(result.some((t) => t.title === 'apq')).toBe(false)
  })

  test('recency (updated desc) orders results within a tier', () => {
    const candidates = [
      c('appA', { updated: 10 }),
      c('appB', { updated: 30 }),
      c('appC', { updated: 20 }),
    ]
    const result = rankCandidates(candidates, 'app')
    expect(result.map((t) => t.title)).toEqual(['appB', 'appC', 'appA'])
  })

  test('dedupe: a candidate matching a stricter tier is not repeated in a looser one', () => {
    // 'app' qualifies for exact; without dedupe it would also satisfy prefix/substring.
    const result = rankCandidates([c('app')], 'app')
    expect(result).toHaveLength(1)
  })
})

describe('candidateItemFields', () => {
  test('an existing page is a plain Reference with no detail', () => {
    const fields = candidateItemFields(true)
    expect(fields.kind).toBe(CompletionItemKind.Reference)
    expect(fields.detail).toBeUndefined()
  })

  test('a red-link candidate is a subtly-marked Text item', () => {
    const fields = candidateItemFields(false)
    expect(fields.kind).toBe(CompletionItemKind.Text)
    expect(fields.detail).toBe('(new)')
  })
})

describe('buildCandidateIndex', () => {
  test('candidate set is page titles ∪ outgoing link targets', () => {
    const titles: TitleEntryLike[] = [
      { title: 'Alpha', links: ['Beta', 'Gamma'] },
      { title: 'Beta', links: [] },
    ]
    const index = buildCandidateIndex(titles)
    const byTitle = new Map(index.map((c) => [c.title, c]))
    expect(byTitle.get('Alpha')?.exists).toBe(true)
    expect(byTitle.get('Beta')?.exists).toBe(true)
    expect(byTitle.get('Gamma')?.exists).toBe(false) // red link: no page named Gamma
    expect(index).toHaveLength(3)
  })

  test('a link target is deduped when a real page has the same normalized title', () => {
    const titles: TitleEntryLike[] = [
      { title: 'CamelCase Page' },
      { title: 'Other', links: ['camelcase_page'] },
    ]
    const index = buildCandidateIndex(titles)
    const matches = index.filter((c) => c.key === normalizeForMatch('CamelCase Page'))
    expect(matches).toHaveLength(1)
    expect(matches[0]?.title).toBe('CamelCase Page') // real page's casing wins
    expect(matches[0]?.exists).toBe(true)
  })

  test('the same red-link target from multiple pages is deduped to one candidate', () => {
    const titles: TitleEntryLike[] = [
      { title: 'A', links: ['Missing'] },
      { title: 'B', links: ['Missing'] },
    ]
    const index = buildCandidateIndex(titles)
    expect(index.filter((c) => c.title === 'Missing')).toHaveLength(1)
  })

  test('tolerant of minimal entries with no links/updated field at all', () => {
    const titles: TitleEntryLike[] = [{ title: 'ホーム' }, { title: 'メモ' }]
    const index = buildCandidateIndex(titles)
    expect(index.map((c) => c.title).sort()).toEqual(['ホーム', 'メモ'])
    expect(index.every((c) => c.exists)).toBe(true)
  })
})
