import { describe, expect, test } from 'bun:test'
import { CompletionItemKind } from 'vscode-languageserver/node'
import {
  buildCandidateIndex,
  type Candidate,
  candidateItemFields,
  detectCompletion,
  detectCompletionInDocument,
  mergeCandidates,
  normalizeForMatch,
  rankCandidates,
  type TitleEntryLike,
  vectorCandidates,
} from './completion'

const cand = (title: string, exists = true): Candidate => ({
  title,
  key: normalizeForMatch(title),
  exists,
  updated: undefined,
})

describe('detectCompletion — multi-word and re-entry', () => {
  test('space inside a closed pair keeps the whole query', () => {
    const line = '[sakura プロモーション]'
    const d = detectCompletion(line, line.length - 1)
    expect(d).not.toBeNull()
    expect(d?.kind).toBe('link')
    expect(d?.query).toBe('sakura プロモーション')
    expect(d?.replaceEnd).toBe(line.length)
  })

  test('cursor inside an existing [..] uses the whole content and replaces the pair', () => {
    const line = 'see [foo] here'
    const d = detectCompletion(line, 7) // "[fo|o]" — cursor mid-content
    expect(d).not.toBeNull()
    expect(d?.replaceStart).toBe(4)
    expect(d?.replaceEnd).toBe(9) // through ']'
    expect(d?.query).toBe('foo') // full bracket content, cursor-position independent
  })

  test('a following [ before any ] -> null (not a closed pair)', () => {
    const line = '[ab [cd]'
    expect(detectCompletion(line, 3)).toBeNull()
  })
})

describe('vectorCandidates', () => {
  test('preserves score order and maps exists', () => {
    const out = vectorCandidates([
      { title: 'Sakura', exists: true },
      { title: 'sakura施策' },
      { title: '未作成ページ', exists: false },
    ])
    expect(out.map((c) => c.title)).toEqual(['Sakura', 'sakura施策', '未作成ページ'])
    expect(out.map((c) => c.exists)).toEqual([true, true, false])
  })

  test('drops entries without a usable title', () => {
    expect(vectorCandidates([{ title: '' }, { title: 'ok' }])).toHaveLength(1)
  })
})

describe('mergeCandidates', () => {
  test('primary order first, fallback fills without duplicates, capped', () => {
    const primary = [cand('A'), cand('B')]
    const fallback = [cand('b'), cand('C'), cand('D')] // 'b' dedupes against 'B'
    const out = mergeCandidates(primary, fallback, 3)
    expect(out.map((c) => c.title)).toEqual(['A', 'B', 'C'])
  })

  test('empty primary falls through to fallback', () => {
    const out = mergeCandidates([], [cand('X')])
    expect(out.map((c) => c.title)).toEqual(['X'])
  })
})

describe('detectCompletion — link', () => {
  test('closed pair mid-line: cursor inside [que|] triggers', () => {
    const line = 'see [que]'
    expect(detectCompletion(line, 8)).toEqual({
      kind: 'link',
      query: 'que',
      replaceStart: 4,
      replaceEnd: 9,
    })
  })

  test('unclosed [ does NOT trigger (Cosense: completion only inside [])', () => {
    expect(detectCompletion('see [que', 8)).toBeNull()
  })

  test('closed [done] -> null (cursor after the closing bracket)', () => {
    const line = 'see [done] already'
    expect(detectCompletion(line, 'see [done]'.length)).toBeNull()
  })

  test('cursor before the closing ] still triggers and replaces the whole bracket', () => {
    // "[do|ne]" — the query is the whole content regardless of cursor position, and
    // accepting a candidate swaps the entire [done] link (Cosense re-entry behavior).
    const line = '[done] more'
    expect(detectCompletion(line, 3)).toEqual({
      kind: 'link',
      query: 'done',
      replaceStart: 0,
      replaceEnd: 6,
    })
  })

  test('`]` right after cursor extends the replace range through it', () => {
    const line = '[foo]'
    // cursor between 'foo' and the closing bracket: "[foo|]"
    const result = detectCompletion(line, 4)
    expect(result).toEqual({ kind: 'link', query: 'foo', replaceStart: 0, replaceEnd: 5 })
  })

  test('no following ] -> null (pair must be closed)', () => {
    expect(detectCompletion('[foo', 4)).toBeNull()
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
    const lines = ['Title', 'see [que]']
    const text = lines.join('\n')
    const character = (lines[1] as string).length - 1
    expect(detectCompletionInDocument(text, { line: 1, character })).toEqual({
      kind: 'link',
      query: 'que',
      replaceStart: 4,
      replaceEnd: character + 1,
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
