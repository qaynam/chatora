import { afterEach, describe, expect, test } from 'bun:test'
import { CompletionItemKind } from 'vscode-languageserver/node'
import {
  asTagName,
  buildCandidateIndex,
  type Candidate,
  type CompletionDetection,
  candidateItemFields,
  detectCompletion,
  detectCompletionInDocument,
  isLinkBracket,
  isTaggable,
  mergeCandidates,
  normalizeForMatch,
  rankCandidates,
  type TitleEntryLike,
  toCompletionItems,
  vectorCandidates,
} from './completion'
import { setNotations } from './notations'

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
      { title: 'sakura の記録' },
      { title: '未作成ページ', exists: false },
    ])
    expect(out.map((c) => c.title)).toEqual(['Sakura', 'sakura の記録', '未作成ページ'])
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
      typedText: '[que',
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
      typedText: '[do',
    })
  })

  test('`]` right after cursor extends the replace range through it', () => {
    const line = '[foo]'
    // cursor between 'foo' and the closing bracket: "[foo|]"
    const result = detectCompletion(line, 4)
    expect(result).toEqual({
      kind: 'link',
      query: 'foo',
      replaceStart: 0,
      replaceEnd: 5,
      typedText: '[foo',
    })
  })

  test('no following ] -> null (pair must be closed)', () => {
    expect(detectCompletion('[foo', 4)).toBeNull()
  })

  test('[[ is not a link trigger (bold/large-image syntax)', () => {
    const line = '[[foo'
    expect(detectCompletion(line, line.length)).toBeNull()
  })
})

describe('isLinkBracket — a plain link, and nothing else', () => {
  const LINKS = [
    ['', 'the pair Cosense just closed for you'],
    ['   ', 'spaces alone are still an empty link'],
    ['foo', 'a title'],
    ['sakura プロモーション', 'a title with a space in it'],
    ['*foo', 'no space after the marker, so it is part of the title'],
    ['-foo', 'the same for a strike marker'],
    ['_private', 'and for an underscore'],
    ['#tag', 'a title that opens with a hash'],
    ['C#入門', 'a hash inside the title'],
    ['100%', 'a percent at the end'],
    ['a/b', 'a slash that is not the first character'],
    ['.icon', 'nothing for .icon to hang on, so it is a title'],
    ['taro.icons', 'not the icon notation'],
    ['next.js', 'an extension that is not an image'],
    ['foo.jpeg?w=1', 'the image extension is not at the end'],
  ] as const
  test.each(LINKS)('%j completes — %s', (inner) => {
    expect(isLinkBracket(inner)).toBe(true)
  })

  const NOTATIONS = [
    ['*', 'a marker with nothing after it yet'],
    ['* ', 'the marker and its space, before the body is typed'],
    ['* 見出し', 'bold'],
    ['*** 大きく', 'a size'],
    ['*-/ 混ぜる', 'a combined run'],
    ['/ 斜体', 'italic'],
    ['- 打ち消し', 'strike'],
    ['_ 下線', 'underline'],
    ['*　全角スペース', 'a full-width space after the run'],
    ['! 重要', 'a Cosense decoration character with no notation configured'],
    ['| 見出し', 'the same for a bar'],
    ['$', 'a formula, before its body'],
    ['$ x^2', 'a formula'],
    ['taro.icon', 'an icon'],
    ['taro.icon*5', 'a repeated icon'],
    ['https://example.com/a', 'a bare URL'],
    ['ラベル https://example.com/a', 'a labelled URL'],
    ['HTTPS://EXAMPLE.COM/A', 'an upper-case scheme'],
    ['foo.png', 'an image named by its extension'],
    ['foo.PNG', 'the extension in upper case'],
    ['/my-project/page', 'a page in another project'],
    ['/my-project', 'another project itself'],
  ] as const
  test.each(NOTATIONS)('%j does not complete — %s', (inner) => {
    expect(isLinkBracket(inner)).toBe(false)
  })
})

describe('isLinkBracket — configured notation markers', () => {
  afterEach(() => setNotations([]))

  test('a marker outside Cosense set counts only once it is configured', () => {
    expect(isLinkBracket('@ メモ')).toBe(true)
    setNotations([{ marker: '@', name: 'note' }])
    expect(isLinkBracket('@ メモ')).toBe(false)
  })

  test('a configured marker still needs the space that makes it a run', () => {
    setNotations([{ marker: '@', name: 'note' }])
    expect(isLinkBracket('@メモ')).toBe(true)
  })
})

describe('detectCompletion — notations do not trigger', () => {
  test('the reported case: [* ] with the cursor after the marker', () => {
    expect(detectCompletion('[* ]', 3)).toBeNull()
  })

  test('anywhere inside a decoration, not just after the marker', () => {
    const line = '[* 見出し]'
    for (const character of [1, 2, 3, 4, 5]) {
      expect(detectCompletion(line, character)).toBeNull()
    }
  })

  test('a link nested in a decoration completes on its own pair', () => {
    const line = '[* [foo]]'
    expect(detectCompletion(line, 7)).toEqual({
      kind: 'link',
      query: 'foo',
      replaceStart: 3,
      replaceEnd: 8,
      typedText: '[foo',
    })
  })

  test('an empty pair nested in a decoration is where typing starts', () => {
    expect(detectCompletion('[* []]', 4)).toEqual({
      kind: 'link',
      query: '',
      replaceStart: 3,
      replaceEnd: 5,
      typedText: '[',
    })
  })

  test('the cursor between the decoration and its nested link does not trigger', () => {
    // "[* |[foo]]" — inside the decoration, which is not a link.
    expect(detectCompletion('[* [foo]]', 3)).toBeNull()
  })

  test('a decoration on a line that also holds a link leaves the link alone', () => {
    const line = '[* 太字] と [ページ]'
    const character = line.indexOf('ページ') + 3
    expect(detectCompletion(line, character)?.query).toBe('ページ')
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
      typedText: '#tag',
    })
  })

  test('just typed # has an empty query', () => {
    const line = '#'
    expect(detectCompletion(line, 1)).toEqual({
      kind: 'hashtag',
      query: '',
      replaceStart: 0,
      replaceEnd: 1,
      typedText: '#',
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
      typedText: '[que',
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

describe('asTagName / isTaggable', () => {
  test('a space is written as an underscore, and still names the same page', () => {
    expect(asTagName('Side Kanban')).toBe('Side_Kanban')
    expect(normalizeForMatch(asTagName('Side Kanban'))).toBe(normalizeForMatch('Side Kanban'))
  })

  test('each space becomes one underscore, so nothing is collapsed', () => {
    expect(asTagName('a  b')).toBe('a__b')
  })

  const TAGGABLE = ['ふつうのページ', 'Side Kanban', 'a-b_c', '100%', 'next.js']
  test.each(TAGGABLE)('%j can be written as a tag', (title) => {
    expect(isTaggable(title)).toBe(true)
  })

  // A tag ends at these, so the page can only be reached as a link.
  const NOT_TAGGABLE = ['C#入門', 'a [b]', 'a]b', '全角　空白', 'tab\there']
  test.each(NOT_TAGGABLE)('%j cannot', (title) => {
    expect(isTaggable(title)).toBe(false)
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

  test('tag mode keeps a title with spaces, which a tag writes with underscores', () => {
    expect(rankCandidates(titles, 'app', { tagsOnly: true }).map((t) => t.title)).toEqual(
      rankCandidates(titles, 'app').map((t) => t.title),
    )
  })

  test('tag mode drops the titles no tag can name', () => {
    const pool = [c('C#入門'), c('a [b]'), c('全角　空白'), c('ふつうのページ')]
    expect(rankCandidates(pool, '', { tagsOnly: true }).map((t) => t.title)).toEqual([
      'ふつうのページ',
    ])
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

describe('toCompletionItems', () => {
  const detection = {
    kind: 'link' as const,
    query: 'foo bar',
    replaceStart: 4,
    replaceEnd: 15,
    typedText: '[foo b',
  }
  const candidates = [
    { title: 'foo bar', key: 'foo bar', exists: true, updated: 1 },
    { title: 'unrelated', key: 'unrelated', exists: false, updated: undefined },
  ]

  test('every item echoes the typed text as filterText, whatever its title', () => {
    // Ranking is fuzzy/semantic, so a client that prefix-filters by filterText
    // must find every item a match — otherwise it drops the ranked list and
    // closes the menu, which also ends the isIncomplete re-query loop.
    for (const item of toCompletionItems(candidates, 2, detection)) {
      expect(item.filterText).toBe('[foo b')
    }
  })

  test('server order is preserved through sortText', () => {
    const items = toCompletionItems(candidates, 2, detection)
    expect(items.map((i) => i.sortText)).toEqual(['0000', '0001'])
    expect(items.map((i) => i.label)).toEqual(['foo bar', 'unrelated'])
  })

  test('accepting an item replaces the whole bracket pair', () => {
    const [item] = toCompletionItems(candidates, 2, detection)
    expect(item?.textEdit).toEqual({
      range: { start: { line: 2, character: 4 }, end: { line: 2, character: 15 } },
      newText: '[foo bar]',
    })
  })

  test('a hashtag is inserted with underscores, while the menu shows the title', () => {
    const tag = detectCompletion('#foo', 4)
    expect(tag).not.toBeNull()
    const [item] = toCompletionItems([candidates[0] as Candidate], 2, tag as CompletionDetection)
    expect(item?.label).toBe('foo bar')
    expect(item?.textEdit).toEqual({
      range: { start: { line: 2, character: 0 }, end: { line: 2, character: 4 } },
      newText: '#foo_bar',
    })
  })
})

describe('fuzzy tier is a fallback', () => {
  const index = buildCandidateIndex(
    Array.from({ length: 40 }, (_, i) => ({ title: `report ${i}`, updated: i })),
  )

  test('does not add near-misses when the literal tiers already filled the list', () => {
    // 'report' matches 40 titles by prefix; nothing fuzzy should be appended.
    const titles = rankCandidates(index, 'report').map((c) => c.title)
    expect(titles).toHaveLength(40)
    expect(titles.every((t) => t.startsWith('report'))).toBe(true)
  })

  test('still rescues a typo when the literal tiers find nothing', () => {
    expect(rankCandidates(index, 'reprot 7').map((c) => c.title)).toContain('report 7')
  })

  test('a single character never triggers a fuzzy scan', () => {
    // 'z' matches no title literally, and fuzzy on one char would match everything.
    expect(rankCandidates(index, 'z')).toEqual([])
  })
})
