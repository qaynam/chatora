import { describe, expect, test } from 'bun:test'
import { computeImageTargets } from './images'

describe('computeImageTargets', () => {
  test('a fragment-tagged URL (#.svg) is an image with its src untouched', () => {
    const text = 'タイトル\n[https://kanban.qaynam.dev/api/status/xxx?userId=yyy#.svg]'
    const targets = computeImageTargets(text)
    expect(targets).toEqual([
      {
        line: 1,
        startChar: 0,
        endChar: '[https://kanban.qaynam.dev/api/status/xxx?userId=yyy#.svg]'.length,
        src: 'https://kanban.qaynam.dev/api/status/xxx?userId=yyy#.svg',
        kind: 'image',
        standalone: true,
      },
    ])
  })

  test('an inline image (surrounded by text) is not standalone', () => {
    const text = 'タイトル\nまえ [https://example.com/pic.png] うしろ'
    const targets = computeImageTargets(text)
    expect(targets).toEqual([
      {
        line: 1,
        startChar: 3,
        endChar: 3 + '[https://example.com/pic.png]'.length,
        src: 'https://example.com/pic.png',
        kind: 'image',
        standalone: false,
      },
    ])
  })

  test('multiple targets on one line come back in source order', () => {
    const text = 'タイトル\n[qaynam.icon] と [foo.icon*3]'
    const targets = computeImageTargets(text)
    expect(targets).toEqual([
      {
        line: 1,
        startChar: 0,
        endChar: 13,
        src: 'qaynam',
        kind: 'icon',
        iconUser: 'qaynam',
        standalone: false,
      },
      {
        line: 1,
        startChar: 16,
        endChar: 28,
        src: 'foo',
        kind: 'icon',
        iconUser: 'foo',
        standalone: false,
      },
    ])
  })

  test('a bare gyazo URL is normalized to i.gyazo.com/<hash>.png', () => {
    const hash = '0123456789abcdef0123456789abcdef01234567'
    const text = `タイトル\n[https://gyazo.com/${hash}]`
    const targets = computeImageTargets(text)
    expect(targets).toEqual([
      {
        line: 1,
        startChar: 0,
        endChar: `[https://gyazo.com/${hash}]`.length,
        src: `https://i.gyazo.com/${hash}.png`,
        kind: 'image',
        standalone: true,
      },
    ])
  })

  test('an already-resolved i.gyazo.com URL passes through unchanged', () => {
    const text = 'タイトル\n[https://i.gyazo.com/abc.png]'
    const targets = computeImageTargets(text)
    expect(targets[0]?.src).toBe('https://i.gyazo.com/abc.png')
  })

  test('an icon: kind, iconUser and standalone, no URL resolution', () => {
    const text = 'タイトル\n[qaynam.icon]'
    const targets = computeImageTargets(text)
    expect(targets).toEqual([
      {
        line: 1,
        startChar: 0,
        endChar: 13,
        src: 'qaynam',
        kind: 'icon',
        iconUser: 'qaynam',
        standalone: true,
      },
    ])
  })

  test('a project icon keeps the /project/name form as iconUser', () => {
    const text = 'タイトル\n[/proj/name.icon]'
    const targets = computeImageTargets(text)
    expect(targets[0]).toMatchObject({ kind: 'icon', iconUser: '/proj/name' })
  })

  test('standalone: true when the line is the image alone (indentation allowed)', () => {
    const text = 'タイトル\n  [https://example.com/img.png]'
    const targets = computeImageTargets(text)
    expect(targets[0]?.standalone).toBe(true)
  })

  test('standalone: false when other non-whitespace content shares the line', () => {
    const text = 'タイトル\n[https://example.com/img.png] caption'
    const targets = computeImageTargets(text)
    expect(targets[0]?.standalone).toBe(false)
  })

  test('standalone: false when nested inside decoration markup', () => {
    const text = 'タイトル\n[* [https://example.com/pic.png]]'
    const targets = computeImageTargets(text)
    expect(targets[0]?.standalone).toBe(false)
  })

  test('code block interiors produce no targets', () => {
    const text = 'タイトル\ncode:x.ts\n [foo.icon]\n [img.png]'
    expect(computeImageTargets(text)).toEqual([])
  })

  test('a large ([[...]]) image is still reported as kind image', () => {
    const text = 'タイトル\n[[https://example.com/big.png]]'
    const targets = computeImageTargets(text)
    expect(targets[0]).toMatchObject({ kind: 'image', src: 'https://example.com/big.png' })
  })
})

describe('only fetchable image URLs become targets', () => {
  // The parser matches image notation on the '#.png'-style suffix alone, so
  // everything here parses as an image node and has to be rejected downstream.
  const rejected = [
    '?userId=8607b16e-4561-4606-b0ea-402d3768bf3d#.svg',
    '/relative/path.png',
    'not a url at all#.svg',
    'javascript:alert(1)#.png',
    'file:///etc/passwd#.png',
    'ftp://example.com/x.png',
  ]

  for (const src of rejected) {
    test(`rejects ${src}`, () => {
      expect(computeImageTargets(`T\n[${src}]`)).toEqual([])
    })
  }

  test('keeps absolute http(s) URLs', () => {
    expect(computeImageTargets('T\n[https://example.com/a.png]')).toHaveLength(1)
    expect(computeImageTargets('T\n[http://example.com/a.png]')).toHaveLength(1)
  })

  test('icons are unaffected — they are resolved to a URL by the client, not carried as one', () => {
    expect(computeImageTargets('T\n[someone.icon]')).toHaveLength(1)
  })
})
