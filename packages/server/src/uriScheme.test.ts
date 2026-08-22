import { describe, expect, test } from 'bun:test'
import { formatUri, parseUri } from './uriScheme'

describe('uriScheme', () => {
  test('round-trips an ascii title, keeping spaces raw', () => {
    const uri = formatUri('myproject', 'Hello World')
    expect(uri).toBe('cosense://myproject/Hello World')
    expect(parseUri(uri)).toEqual({ project: 'myproject', title: 'Hello World' })
  })

  test('keeps a Japanese title raw (readable as a buffer name) and round-trips', () => {
    const title = '日本語のタイトル'
    const uri = formatUri('myproject', title)
    expect(uri).toBe(`cosense://myproject/${title}`)
    expect(parseUri(uri)).toEqual({ project: 'myproject', title })
  })

  test('still parses a fully percent-encoded title (older buffers, hand-typed uris)', () => {
    expect(parseUri('cosense://myproject/%E3%83%A1%E3%83%A2')).toEqual({
      project: 'myproject',
      title: 'メモ',
    })
  })

  test('round-trips a title containing reserved uri characters', () => {
    const title = 'a/b?c#d%e'
    const uri = formatUri('proj', title)
    expect(parseUri(uri)).toEqual({ project: 'proj', title })
  })

  test('parseUri rejects non-cosense uris', () => {
    expect(parseUri('https://example.com/foo')).toBeNull()
    expect(parseUri('cosense://')).toBeNull()
    expect(parseUri('not a uri')).toBeNull()
  })

  test('parseUri accepts an empty title', () => {
    expect(parseUri('cosense://myproject/')).toEqual({ project: 'myproject', title: '' })
  })
})
