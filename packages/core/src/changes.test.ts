import { describe, expect, test } from 'bun:test'
import { alignLines, computeChanges } from './changes'

const idSeq = (): (() => string) => {
  let n = 0
  return () => `new${n++}`
}

describe('computeChanges', () => {
  test('no-op when next matches base exactly', () => {
    const base = [
      { id: 'a', text: 'A' },
      { id: 'b', text: 'B' },
    ]
    expect(computeChanges(base, ['A', 'B'], idSeq())).toEqual([])
  })

  test('pure insert at the end', () => {
    const base = [{ id: 'a', text: 'A' }]
    const changes = computeChanges(base, ['A', 'B'], idSeq())
    expect(changes).toEqual([{ _insert: '_end', lines: { id: 'new0', text: 'B' } }])
  })

  test('pure insert at the start', () => {
    const base = [{ id: 'a', text: 'A' }]
    const changes = computeChanges(base, ['X', 'A'], idSeq())
    expect(changes).toEqual([{ _insert: 'a', lines: { id: 'new0', text: 'X' } }])
  })

  test('pure insert in the middle', () => {
    const base = [
      { id: 'a', text: 'A' },
      { id: 'b', text: 'B' },
    ]
    const changes = computeChanges(base, ['A', 'X', 'B'], idSeq())
    expect(changes).toEqual([{ _insert: 'b', lines: { id: 'new0', text: 'X' } }])
  })

  test('pure delete', () => {
    const base = [
      { id: 'a', text: 'A' },
      { id: 'b', text: 'B' },
    ]
    const changes = computeChanges(base, ['A'], idSeq())
    expect(changes).toEqual([{ _delete: 'b' }])
  })

  test('delete from the middle', () => {
    const base = [
      { id: 'a', text: 'A' },
      { id: 'b', text: 'B' },
      { id: 'c', text: 'C' },
    ]
    const changes = computeChanges(base, ['A', 'C'], idSeq())
    expect(changes).toEqual([{ _delete: 'b' }])
  })

  test('single-line update in place', () => {
    const base = [{ id: 'a', text: 'A' }]
    const changes = computeChanges(base, ['A2'], idSeq())
    expect(changes).toEqual([{ _update: 'a', lines: { text: 'A2' } }])
  })

  test('mixed: update + trailing insert at end, kept lines untouched', () => {
    const base = [
      { id: 'a', text: 'A' },
      { id: 'b', text: 'B' },
      { id: 'c', text: 'C' },
    ]
    const changes = computeChanges(base, ['A', 'X', 'C', 'D'], idSeq())
    expect(changes).toEqual([
      { _update: 'b', lines: { text: 'X' } },
      { _insert: '_end', lines: { id: 'new0', text: 'D' } },
    ])
  })

  test('mixed: shrinking a block emits update then delete for the remainder', () => {
    const base = [
      { id: 'a', text: 'A' },
      { id: 'b', text: 'B' },
      { id: 'c', text: 'C' },
      { id: 'd', text: 'D' },
    ]
    const changes = computeChanges(base, ['A', 'X', 'D'], idSeq())
    expect(changes).toEqual([{ _update: 'b', lines: { text: 'X' } }, { _delete: 'c' }])
  })

  test('mixed: growing a block emits update then insert anchored on the next kept line', () => {
    const base = [
      { id: 'a', text: 'A' },
      { id: 'b', text: 'B' },
      { id: 'c', text: 'C' },
    ]
    const changes = computeChanges(base, ['A', 'X', 'Y', 'C'], idSeq())
    expect(changes).toEqual([
      { _update: 'b', lines: { text: 'X' } },
      { _insert: 'c', lines: { id: 'new0', text: 'Y' } },
    ])
  })

  test('empty base: every line becomes an _insert at _end, in order (new page)', () => {
    const changes = computeChanges([], ['Title', 'line1', 'line2'], idSeq())
    expect(changes).toEqual([
      { _insert: '_end', lines: { id: 'new0', text: 'Title' } },
      { _insert: '_end', lines: { id: 'new1', text: 'line1' } },
      { _insert: '_end', lines: { id: 'new2', text: 'line2' } },
    ])
  })

  test('next entirely empty deletes every base line', () => {
    const base = [
      { id: 'a', text: 'A' },
      { id: 'b', text: 'B' },
    ]
    const changes = computeChanges(base, [], idSeq())
    expect(changes).toEqual([{ _delete: 'a' }, { _delete: 'b' }])
  })

  test('both empty is a no-op', () => {
    expect(computeChanges([], [], idSeq())).toEqual([])
  })
})

describe('alignLines', () => {
  const base = [
    { id: 'a', text: 'A', updated: 100 },
    { id: 'b', text: 'B', updated: 200 },
    { id: 'c', text: 'C', updated: 300 },
  ]

  test('an untouched document maps every line onto its own base line', () => {
    expect(alignLines(base, ['A', 'B', 'C']).map((l) => l?.id)).toEqual(['a', 'b', 'c'])
  })

  test('inserted lines map to nothing, and the lines around them keep their base', () => {
    expect(alignLines(base, ['A', 'new', 'B', 'C']).map((l) => l?.id)).toEqual([
      'a',
      undefined,
      'b',
      'c',
    ])
  })

  test('an edited line loses its base line: its text is no longer what the server holds', () => {
    expect(alignLines(base, ['A', 'B edited', 'C']).map((l) => l?.id)).toEqual([
      'a',
      undefined,
      'c',
    ])
  })

  test('a deleted line shifts nothing: the survivors keep their own base lines', () => {
    expect(alignLines(base, ['A', 'C']).map((l) => l?.id)).toEqual(['a', 'c'])
  })

  test('the whole base line comes back, not just its id', () => {
    expect(alignLines(base, ['B'])[0]).toEqual({ id: 'b', text: 'B', updated: 200 })
  })

  test('an empty document aligns to nothing at all', () => {
    expect(alignLines(base, [])).toEqual([])
  })

  test('every line of a document with no base is unmatched', () => {
    expect(alignLines([], ['A', 'B'])).toEqual([undefined, undefined])
  })
})
