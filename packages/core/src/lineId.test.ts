import { describe, expect, test } from 'bun:test'
import { createNewLineId } from './lineId'

describe('createNewLineId', () => {
  test('produces 24 lowercase hex chars, matching cosense-cli randomBytes(12).toString("hex")', () => {
    expect(createNewLineId()).toMatch(/^[0-9a-f]{24}$/)
  })

  test('generates unique ids across many calls', () => {
    const ids = new Set(Array.from({ length: 1000 }, () => createNewLineId()))
    expect(ids.size).toBe(1000)
  })
})
