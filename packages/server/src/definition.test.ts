import { describe, expect, test } from 'bun:test'
import { definitionLocation, findDefinitionTarget } from './definition'

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
      uri: 'cosense://myproject/Some%20Page',
      range: { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } },
    })
  })
})
