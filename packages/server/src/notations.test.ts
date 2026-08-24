import { afterEach, describe, expect, test } from 'bun:test'
import { parse, parseLine } from '@cosense-toolbox/parser'
import {
  notationName,
  notationNameForDecoration,
  notationSpecs,
  parseOptions,
  setNotations,
} from './notations'

describe('setNotations / parseOptions', () => {
  test('empty spec set produces no options — official parsing is unaffected', () => {
    setNotations([])
    expect(parseOptions()).toBeUndefined()
    const line = parseLine('[| not configured]', parseOptions())
    const bracket = line.children[0]
    expect(bracket?.type).toBe('internalLink')
  })

  test('an unconfigured marker still resolves as internalLink even with other notations active', () => {
    setNotations([{ marker: '=', name: 'boxed' }])
    const line = parseLine('[| still a link]', parseOptions())
    expect(line.children[0]?.type).toBe('internalLink')
    setNotations([])
  })

  test('a configured marker becomes a decoration node with no styling flags set', () => {
    setNotations([{ marker: '|', name: 'highlight' }])
    const line = parseLine('[| hello world]', parseOptions())
    const node = line.children[0]
    expect(node?.type).toBe('decoration')
    if (node?.type === 'decoration') {
      expect(node.bold).toBe(false)
      expect(node.italic).toBe(false)
      expect(node.strike).toBe(false)
      expect(node.underline).toBe(false)
      expect(node.sizeLevel).toBe(0)
      expect(node.value).toBe('hello world')
    }
    setNotations([])
  })

  test('body-empty bracket (marker with no content after the whitespace) does not match', () => {
    setNotations([{ marker: '|', name: 'highlight' }])
    const line = parseLine('[| ]', parseOptions())
    expect(line.children[0]?.type).toBe('internalLink')
    setNotations([])
  })

  test('marker with no following whitespace does not match', () => {
    setNotations([{ marker: '|', name: 'highlight' }])
    const line = parseLine('[|nope]', parseOptions())
    expect(line.children[0]?.type).toBe('internalLink')
    setNotations([])
  })

  test('child node column accounts for marker + whitespace, at any offset in the source', () => {
    setNotations([{ marker: '|', name: 'highlight' }])
    const src = 'Title\nまえ [| ハイライト] うしろ'
    const page = parse(src, parseOptions())
    const line = page.children[1]
    if (line?.type !== 'line') throw new Error('expected a line block')
    const deco = line.children.find((c) => c.type === 'decoration')
    if (deco?.type !== 'decoration') throw new Error('expected a decoration node')

    // '[| ' is 3 code units; the decoration starts right after 'まえ '.
    const bracketStart = src.split('\n')[1]?.indexOf('[|') as number
    expect(deco.position.start.column).toBe(bracketStart)
    const child = deco.children[0]
    expect(child?.position.start.column).toBe(bracketStart + 3)
    setNotations([])
  })

  test('multiple markers each resolve to their own name', () => {
    setNotations([
      { marker: '|', name: 'highlight' },
      { marker: '=', name: 'boxed' },
    ])
    const highlightLine = parseLine('[| a]', parseOptions())
    const boxedLine = parseLine('[= b]', parseOptions())
    expect(highlightLine.children[0]?.type).toBe('decoration')
    expect(boxedLine.children[0]?.type).toBe('decoration')
    expect(notationName('|')).toBe('highlight')
    expect(notationName('=')).toBe('boxed')
    setNotations([])
  })

  test('notationSpecs is canonicalized to marker-ascending order regardless of input order', () => {
    setNotations([
      { marker: '~', name: 'z' },
      { marker: '!', name: 'a' },
    ])
    expect(notationSpecs().map((s) => s.marker)).toEqual(['!', '~'])
    setNotations([])
  })
})

describe('notationNameForDecoration', () => {
  afterEach(() => setNotations([]))

  const decorationNodeOf = (src: string) => {
    const node = parseLine(src, parseOptions()).children[0]
    if (node?.type !== 'decoration') throw new Error('expected a decoration node')
    return node
  }

  test('resolves the marker at the node position back to its configured name', () => {
    setNotations([{ marker: '|', name: 'highlight' }])
    expect(notationNameForDecoration(decorationNodeOf('[| hi]'), ['[| hi]'])).toBe('highlight')
  })

  test('an official decoration marker never resolves to a name', () => {
    setNotations([{ marker: '|', name: 'highlight' }])
    expect(notationNameForDecoration(decorationNodeOf('[* hi]'), ['[* hi]'])).toBeUndefined()
  })
})
