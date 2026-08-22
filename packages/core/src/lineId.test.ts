import { describe, expect, test } from 'bun:test'
import { createNewLineId } from './lineId'

describe('createNewLineId', () => {
  test('produces 24 lowercase hex chars, matching cosense-cli randomBytes(12).toString("hex")', () => {
    const id = createNewLineId('user-123')
    expect(id).toMatch(/^[0-9a-f]{24}$/)
  })

  test('is not derived from userId (matches cosense-cli semantics exactly)', () => {
    const a = createNewLineId('user-a')
    const b = createNewLineId('user-a')
    expect(a).not.toBe(b)
  })

  test('generates unique ids across many calls', () => {
    const ids = new Set(Array.from({ length: 1000 }, () => createNewLineId('user-1')))
    expect(ids.size).toBe(1000)
  })
})
