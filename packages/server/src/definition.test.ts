import { describe, expect, test } from 'bun:test'
import { definitionLocation, findDefinitionTarget, findUrlTarget } from './definition'

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
