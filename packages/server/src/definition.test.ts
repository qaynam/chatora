import { describe, expect, test } from 'bun:test'
import { definitionLocation, findDefinitionTarget, findUrlTarget, splitLineRef } from './definition'

describe('findDefinitionTarget', () => {
  test('internalLink under the cursor resolves within the current project', () => {
    const line = 'see [Some Page] here'
    const character = line.indexOf('Some')
    expect(findDefinitionTarget(line, character, 'myproject')).toEqual({
      project: 'myproject',
      title: 'Some Page',
    })
  })

  test('hashtag under the cursor resolves within the current project', () => {
    const line = 'note #tagged here'
    const character = line.indexOf('#tagged') + 2
    expect(findDefinitionTarget(line, character, 'myproject')).toEqual({
      project: 'myproject',
      title: 'tagged',
    })
  })

  test('projectLink resolves to its own project, not the current one', () => {
    const line = 'see [/other/Some Page] here'
    const character = line.indexOf('other')
    expect(findDefinitionTarget(line, character, 'myproject')).toEqual({
      project: 'other',
      title: 'Some Page',
    })
  })

  test('externalLink is not a definition target', () => {
    const line = 'see [https://example.com] here'
    const character = line.indexOf('example')
    expect(findDefinitionTarget(line, character, 'myproject')).toBeNull()
  })

  test('cursor outside any link -> null', () => {
    const line = 'see [Some Page] here'
    const character = line.indexOf('here')
    expect(findDefinitionTarget(line, character, 'myproject')).toBeNull()
  })
})

describe('definitionLocation', () => {
  test('builds a cosense:// uri pointing at the top of the target page', () => {
    expect(definitionLocation({ project: 'myproject', title: 'Some Page' })).toEqual({
      uri: 'cosense://myproject/Some Page',
      range: { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } },
    })
  })
})

describe('findUrlTarget', () => {
  const IMAGE = 'https://kanban.qaynam.dev/api/status/x?userId=1#.svg'
  const LINK = 'https://github.com/qaynam/mooconn-web/pull/22'

  test('a linked image opens its link, not the image it renders', () => {
    const line = `[${IMAGE} ${LINK}]`
    expect(findUrlTarget(line, 1)).toBe(LINK)
    expect(findUrlTarget(line, line.length - 2)).toBe(LINK)
  })

  test('a plain image opens itself', () => {
    expect(findUrlTarget('[https://example.com/pic.png]', 3)).toBe('https://example.com/pic.png')
  })

  test('an external link opens its target, whichever side the URL is on', () => {
    expect(findUrlTarget(`[ラベル ${LINK}]`, 2)).toBe(LINK)
    expect(findUrlTarget(`[${LINK} ラベル]`, 2)).toBe(LINK)
  })

  test('page links and plain text are left to the definition jump', () => {
    expect(findUrlTarget('see [ページ名] here', 6)).toBeNull()
    expect(findUrlTarget('#tag', 2)).toBeNull()
    expect(findUrlTarget('just text', 3)).toBeNull()
  })
})

describe('line links', () => {
  // Cosense writes `[title#lineId]` for a link to one line of a page. A title may contain a
  // `#` of its own, so only the 24-hex-character shape of a line id counts as one.
  test('splits a line reference off the page title', () => {
    expect(splitLineRef('pagetitle#6a44c8050000000000650784')).toEqual({
      title: 'pagetitle',
      lineId: '6a44c8050000000000650784',
    })
  })

  test('leaves a title that merely contains # alone', () => {
    expect(splitLineRef('C#入門')).toEqual({ title: 'C#入門' })
    expect(splitLineRef('page#short')).toEqual({ title: 'page#short' })
    expect(splitLineRef('#hash')).toEqual({ title: '#hash' })
  })

  test('gd on one reports the page and the line', () => {
    const target = findDefinitionTarget('[メモ#6a44c8050000000000650784] を見る', 2, 'proj')
    expect(target).toEqual({
      project: 'proj',
      title: 'メモ',
      lineId: '6a44c8050000000000650784',
    })
  })

  test('a project link can name a line too', () => {
    const target = findDefinitionTarget('[/other/メモ#6a44c8050000000000650784]', 3, 'proj')
    expect(target).toMatchObject({
      project: 'other',
      title: 'メモ',
      lineId: '6a44c8050000000000650784',
    })
  })

  test('the location points at the row the caller resolved', () => {
    const at = definitionLocation({ project: 'proj', title: 'メモ' }, 7)
    expect(at.range.start.line).toBe(7)
    expect(at.range.end.line).toBe(7)
  })
})
