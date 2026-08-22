import { describe, expect, test } from 'bun:test'
import { formatUri, parseUri } from './uriScheme'

describe('uriScheme', () => {
  test('round-trips an ascii title', () => {
    const uri = formatUri('myproject', 'Hello World')
    expect(uri).toBe('cosense://myproject/Hello%20World')
    expect(parseUri(uri)).toEqual({ project: 'myproject', title: 'Hello World' })
  })

  test('round-trips a Japanese title', () => {
    const title = '日本語のタイトル'
    const uri = formatUri('myproject', title)
    expect(uri).toContain('%')
    expect(parseUri(uri)).toEqual({ project: 'myproject', title })
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
