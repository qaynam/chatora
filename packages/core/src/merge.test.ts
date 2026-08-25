import { describe, expect, test } from 'bun:test'
import type { BaseLine } from './changes'
import { mergeThreeWay } from './merge'

const lines = (...texts: string[]): BaseLine[] =>
  texts.map((text, i) => ({ id: `l${i + 1}`, text }))

/** Same ids as `lines`, so a caller can rewrite one line's text without renumbering. */
const withText = (base: readonly BaseLine[], at: number, text: string): BaseLine[] =>
  base.map((line, i) => (i === at ? { ...line, text } : line))

const BASE = lines('title', 'alpha', 'beta', 'gamma')

describe('mergeThreeWay', () => {
  test('nothing changed on either side', () => {
    const result = mergeThreeWay(BASE, ['title', 'alpha', 'beta', 'gamma'], BASE)
    expect(result.merged).toEqual(['title', 'alpha', 'beta', 'gamma'])
    expect(result.conflicts).toEqual([])
  })

  test('remote-only edits are taken', () => {
    const theirs = withText(BASE, 2, 'BETA')
    const result = mergeThreeWay(BASE, ['title', 'alpha', 'beta', 'gamma'], theirs)
    expect(result.merged).toEqual(['title', 'alpha', 'BETA', 'gamma'])
    expect(result.conflicts).toEqual([])
  })

  test('local-only edits are kept', () => {
    const result = mergeThreeWay(BASE, ['title', 'ALPHA', 'beta', 'gamma'], BASE)
    expect(result.merged).toEqual(['title', 'ALPHA', 'beta', 'gamma'])
    expect(result.conflicts).toEqual([])
  })

  test('edits to different lines compose', () => {
    const theirs = withText(BASE, 3, 'GAMMA')
    const result = mergeThreeWay(BASE, ['title', 'ALPHA', 'beta', 'gamma'], theirs)
    expect(result.merged).toEqual(['title', 'ALPHA', 'beta', 'GAMMA'])
    expect(result.conflicts).toEqual([])
  })

  test('the same edit on both sides is not a conflict', () => {
    const theirs = withText(BASE, 1, 'ALPHA')
    const result = mergeThreeWay(BASE, ['title', 'ALPHA', 'beta', 'gamma'], theirs)
    expect(result.merged).toEqual(['title', 'ALPHA', 'beta', 'gamma'])
    expect(result.conflicts).toEqual([])
  })

  test('a line both sides edited keeps the local text and reports the remote one', () => {
    const theirs = withText(BASE, 1, 'theirs')
    const result = mergeThreeWay(BASE, ['title', 'ours', 'beta', 'gamma'], theirs)
    expect(result.merged).toEqual(['title', 'ours', 'beta', 'gamma'])
    expect(result.conflicts).toEqual([{ line: 1, ours: 'ours', theirs: 'theirs', base: 'alpha' }])
  })

  test('remote insertions land in remote order', () => {
    const theirs = [...BASE.slice(0, 2), { id: 'r1', text: 'new remote' }, ...BASE.slice(2)]
    const result = mergeThreeWay(BASE, ['title', 'alpha', 'beta', 'gamma'], theirs)
    expect(result.merged).toEqual(['title', 'alpha', 'new remote', 'beta', 'gamma'])
    expect(result.conflicts).toEqual([])
  })

  test('local insertions survive a remote insertion elsewhere', () => {
    const theirs = [...BASE, { id: 'r1', text: 'remote tail' }]
    const result = mergeThreeWay(BASE, ['title', 'alpha', 'mine', 'beta', 'gamma'], theirs)
    expect(result.merged).toEqual(['title', 'alpha', 'mine', 'beta', 'gamma', 'remote tail'])
    expect(result.conflicts).toEqual([])
  })

  test('a local append and a remote append both survive', () => {
    const theirs = [...BASE, { id: 'r1', text: 'remote tail' }]
    const result = mergeThreeWay(BASE, [...BASE.map((l) => l.text), 'local tail'], theirs)
    expect(result.merged).toContain('local tail')
    expect(result.merged).toContain('remote tail')
  })

  test('a remote deletion of an untouched line is taken', () => {
    const theirs = BASE.filter((l) => l.id !== 'l3')
    const result = mergeThreeWay(BASE, ['title', 'alpha', 'beta', 'gamma'], theirs)
    expect(result.merged).toEqual(['title', 'alpha', 'gamma'])
    expect(result.conflicts).toEqual([])
  })

  test('a local deletion of an untouched line is kept', () => {
    const result = mergeThreeWay(BASE, ['title', 'alpha', 'gamma'], BASE)
    expect(result.merged).toEqual(['title', 'alpha', 'gamma'])
    expect(result.conflicts).toEqual([])
  })

  // The invariant that matters most: the server deleting a line must not take a local
  // edit to that line with it.
  test('a remote deletion never swallows a local edit', () => {
    const theirs = BASE.filter((l) => l.id !== 'l2')
    const result = mergeThreeWay(BASE, ['title', 'my important edit', 'beta', 'gamma'], theirs)
    expect(result.merged).toContain('my important edit')
    expect(result.conflicts).toEqual([
      { line: 1, ours: 'my important edit', theirs: null, base: 'alpha' },
    ])
  })

  test('a remote edit to a locally deleted line comes back, flagged', () => {
    const theirs = withText(BASE, 1, 'they kept working on it')
    const result = mergeThreeWay(BASE, ['title', 'beta', 'gamma'], theirs)
    expect(result.merged).toEqual(['title', 'they kept working on it', 'beta', 'gamma'])
    expect(result.conflicts).toEqual([
      { line: 1, ours: null, theirs: 'they kept working on it', base: 'alpha' },
    ])
  })

  test('a locally edited line follows a remote reorder', () => {
    const theirs = [BASE[0], BASE[3], BASE[1], BASE[2]] as BaseLine[]
    const result = mergeThreeWay(BASE, ['title', 'ALPHA', 'beta', 'gamma'], theirs)
    expect(result.merged).toEqual(['title', 'gamma', 'ALPHA', 'beta'])
    expect(result.conflicts).toEqual([])
  })

  test('a page emptied on the server still holds every local edit', () => {
    const result = mergeThreeWay(BASE, ['title', 'ALPHA', 'beta', 'gamma', 'mine'], [])
    expect(result.merged).toContain('ALPHA')
    expect(result.merged).toContain('mine')
  })

  test('a page that did not exist yet is all local', () => {
    const result = mergeThreeWay([], ['title', 'body'], [])
    expect(result.merged).toEqual(['title', 'body'])
    expect(result.conflicts).toEqual([])
  })

  test('an untouched buffer takes the remote wholesale', () => {
    const theirs = lines('title', 'completely', 'different', 'now')
    const result = mergeThreeWay(
      BASE,
      BASE.map((l) => l.text),
      theirs,
    )
    expect(result.merged).toEqual(['title', 'completely', 'different', 'now'])
    expect(result.conflicts).toEqual([])
  })
})

describe('mergeThreeWay never loses local text', () => {
  // Every local line that is not in `base` is something the user typed and has not saved.
  // Whatever the server did, it has to come out the other side.
  const cases: { readonly name: string; readonly ours: string[]; readonly theirs: BaseLine[] }[] = [
    { name: 'remote untouched', ours: ['title', 'x', 'beta', 'gamma'], theirs: BASE },
    {
      name: 'remote edited the same line',
      ours: ['title', 'x', 'beta', 'gamma'],
      theirs: withText(BASE, 1, 'T'),
    },
    {
      name: 'remote deleted the line',
      ours: ['title', 'x', 'beta', 'gamma'],
      theirs: BASE.filter((l) => l.id !== 'l2'),
    },
    { name: 'remote deleted everything', ours: ['title', 'x', 'beta', 'gamma'], theirs: [] },
    {
      name: 'remote replaced everything',
      ours: ['title', 'x', 'beta', 'gamma'],
      theirs: lines('a', 'b'),
    },
    {
      name: 'remote reordered',
      ours: ['title', 'x', 'beta', 'gamma'],
      theirs: [BASE[3], BASE[0], BASE[1], BASE[2]] as BaseLine[],
    },
    {
      name: 'local insert, remote deleted the anchor',
      ours: ['title', 'alpha', 'x', 'beta', 'gamma'],
      theirs: BASE.filter((l) => l.id !== 'l3'),
    },
    {
      name: 'local insert at the very top',
      ours: ['x', 'title', 'alpha', 'beta', 'gamma'],
      theirs: withText(BASE, 0, 'retitled'),
    },
  ]

  for (const { name, ours, theirs } of cases) {
    test(name, () => {
      expect(mergeThreeWay(BASE, ours, theirs).merged).toContain('x')
    })
  }
})
