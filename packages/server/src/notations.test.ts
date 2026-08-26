import { afterEach, describe, expect, test } from 'bun:test'
import { parse, parseLine } from '@cosense-toolbox/parser'
import {
  notationName,
  notationNameForDecoration,
  notationNamesForDecoration,
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

  test('a decoration character with no notation behind it rides along in the run', () => {
    setNotations([{ marker: '!', name: 'important' }])
    const node = parseLine("[!' お願い]", parseOptions()).children[0]
    expect(node?.type).toBe('decoration')
    if (node?.type === 'decoration') {
      expect(node.value).toBe('お願い')
      expect(node.markers).toEqual(['!', "'"])
      expect(notationNamesForDecoration(node)).toEqual(['important'])
    }
    setNotations([])
  })

  test('a character Cosense would not take as a marker ends the run, leaving a link', () => {
    setNotations([{ marker: '!', name: 'important' }])
    expect(parseLine('[!x お願い]', parseOptions()).children[0]?.type).toBe('internalLink')
    setNotations([])
  })

  test("a configured marker outside Cosense's own set still opens a run", () => {
    setNotations([{ marker: '=', name: 'boxed' }])
    expect(parseLine('[=! 予約文字でも設定次第]', parseOptions()).children[0]?.type).toBe(
      'decoration',
    )
    setNotations([])
  })

  test('every configured notation in a run is reported, in the order written', () => {
    setNotations([
      { marker: '!', name: 'important' },
      { marker: '{', name: 'balloon' },
    ])
    for (const [src, expected] of [
      ['[!{ text]', ['important', 'balloon']],
      ['[{! text]', ['balloon', 'important']],
      ['[!!{ text]', ['important', 'balloon']],
    ] as const) {
      const node = parseLine(src, parseOptions()).children[0]
      expect(node?.type).toBe('decoration')
      if (node?.type === 'decoration')
        expect(notationNamesForDecoration(node)).toEqual([...expected])
    }
    setNotations([])
  })

  test('a marker run mixing a notation with official markers keeps both, in either order', () => {
    setNotations([{ marker: '|', name: 'highlight' }])
    for (const src of ['[|* 特徴]', '[*| 特徴]']) {
      const node = parseLine(src, parseOptions()).children[0]
      expect(node?.type).toBe('decoration')
      if (node?.type !== 'decoration') continue
      expect(node.bold).toBe(true)
      expect(node.value).toBe('特徴')
      expect(notationNameForDecoration(node)).toBe('highlight')
    }
    setNotations([])
  })

  test('asterisk count in a mixed run still grades sizeLevel, capped like the official parser', () => {
    setNotations([{ marker: '|', name: 'highlight' }])
    const sizeOf = (src: string) => {
      const node = parseLine(src, parseOptions()).children[0]
      if (node?.type !== 'decoration') throw new Error('expected a decoration node')
      return node.sizeLevel
    }
    expect(sizeOf('[|* a]')).toBe(0)
    expect(sizeOf('[|** a]')).toBe(1)
    expect(sizeOf('[|******* a]')).toBe(4)
    setNotations([])
  })

  test('a run of official markers only is left to the base parser', () => {
    setNotations([{ marker: '|', name: 'highlight' }])
    const node = parseLine('[-_ a]', parseOptions()).children[0]
    expect(node?.type).toBe('decoration')
    if (node?.type === 'decoration') {
      expect(node.strike).toBe(true)
      expect(node.underline).toBe(true)
      expect(notationNameForDecoration(node)).toBeUndefined()
    }
    setNotations([])
  })

  test('child column accounts for the whole marker run', () => {
    setNotations([{ marker: '|', name: 'highlight' }])
    const node = parseLine('[|** 特徴]', parseOptions()).children[0]
    if (node?.type !== 'decoration') throw new Error('expected a decoration node')
    expect(node.children[0]?.position.start.column).toBe('[|** '.length)
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
    expect(notationNameForDecoration(decorationNodeOf('[| hi]'))).toBe('highlight')
  })

  test('an official decoration marker never resolves to a name', () => {
    setNotations([{ marker: '|', name: 'highlight' }])
    expect(notationNameForDecoration(decorationNodeOf('[* hi]'))).toBeUndefined()
  })

  test('the node carries the markers as written, in order and without repeats', () => {
    setNotations([{ marker: '|', name: 'highlight' }])
    expect(decorationNodeOf('[|* hi]').markers).toEqual(['|', '*'])
    expect(decorationNodeOf('[*** hi]').markers).toEqual(['*'])
    setNotations([])
  })
})
