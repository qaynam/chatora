import { describe, expect, test } from 'bun:test'
import { computeChanges } from './changes'

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
