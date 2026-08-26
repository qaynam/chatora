import type { Decoration, Extension, ParseOptions } from '@cosense-toolbox/parser'
import { Option } from 'effect'

/** One user-defined `[<marker> body]` notation, wired to a semantic token type named `name`. */
export interface NotationSpec {
  readonly marker: string
  readonly name: string
}

// Not part of the package's public exports (only Extension is) — recovered from its shape.
type BracketRule = NonNullable<Extension['bracketRules']>[number]

const WHITESPACE_RE = /\s/

/** The only marker characters the base parser styles on its own; anything else needs a spec. */
const OFFICIAL_MARKERS = {
  '*': 'bold',
  '/': 'italic',
  '-': 'strike',
  _: 'underline',
} as const satisfies Record<string, 'bold' | 'italic' | 'strike' | 'underline'>

/** Cosense stops growing emphasis at five asterisks; sizeLevel is 0-indexed. */
const MAX_SIZE_LEVEL = 4

/**
 * Every character Cosense accepts inside a marker run, from help-jp/文字装飾記法:
 *
 * > `*`や`/`だけでなく、`!"#%&'()*+,-./{|}<>_~`などの記号も使用できます
 *
 * Only a handful of them carry a look of their own. The web client turns every character
 * into a CSS class (`deco-!`, `deco-{`, …) and leaves the look to the project's stylesheet;
 * chatora looks it up among the configured notations instead. `=` is accepted there too,
 * but documented as reserved for a use of Cosense's own.
 *
 * A character in this set with no notation behind it styles nothing and stops nothing: the
 * same page warns the set changes without notice, and dropping the whole decoration —
 * leaving `[!' text]` to read as a link to a page named `!' text` — is the worse answer.
 */
const DECORATION_CHARS = new Set(`!"#%&'()*+,-./{|}<>_~`.split(''))

interface MarkerRun {
  /** Names of the user-defined notations in the run, in the order they were written. */
  readonly notations: readonly string[]
  /** The marker characters as written, in order and without repeats. */
  readonly markers: readonly string[]
  /** Offset of the body within `inner`, past the run and the whitespace after it. */
  readonly bodyStart: number
  readonly bold: boolean
  readonly italic: boolean
  readonly strike: boolean
  readonly underline: boolean
  readonly sizeLevel: number
}

/**
 * A Cosense decoration marker is a *run* of marker characters, not a single one:
 * `[|* text]` carries both `|` and `*`, and every character in the run applies.
 *
 * Undefined unless the run holds a user-defined marker and is followed by whitespace and
 * a non-empty body: an official-only run is the base parser's to handle, and the rest are
 * plain links.
 */
const scanMarkerRun = (
  inner: string,
  markers: ReadonlyMap<string, string>,
): MarkerRun | undefined => {
  const flags = { bold: false, italic: false, strike: false, underline: false }
  const written: string[] = []
  const notations: string[] = []
  let asterisks = 0
  let end = 0
  const record = (char: string) => {
    if (!written.includes(char)) written.push(char)
  }
  for (; end < inner.length; end++) {
    const char = inner[end] as string
    const official = OFFICIAL_MARKERS[char as keyof typeof OFFICIAL_MARKERS]
    if (official !== undefined) {
      flags[official] = true
      record(char)
      if (char === '*') asterisks++
      continue
    }
    const name = markers.get(char)
    // A configured marker is in the run whatever Cosense thinks of the character; an
    // unconfigured one only if Cosense would have taken it as part of the run too.
    if (name === undefined && !DECORATION_CHARS.has(char)) break
    record(char)
    if (name !== undefined && !notations.includes(name)) notations.push(name)
  }
  if (notations.length === 0) return undefined

  let bodyStart = end
  while (bodyStart < inner.length && WHITESPACE_RE.test(inner[bodyStart] as string)) bodyStart++
  if (bodyStart === end || bodyStart === inner.length) return undefined

  return {
    notations,
    markers: written,
    bodyStart,
    ...flags,
    sizeLevel: Math.min(Math.max(asterisks - 1, 0), MAX_SIZE_LEVEL),
  }
}

const buildRule =
  (markers: ReadonlyMap<string, string>): BracketRule =>
  (inner, ctx) => {
    const run = scanMarkerRun(inner, markers)
    if (run === undefined) return Option.none()
    const body = inner.slice(run.bodyStart)
    return Option.some({
      type: 'decoration',
      value: body,
      markers: run.markers,
      bold: run.bold,
      italic: run.italic,
      strike: run.strike,
      underline: run.underline,
      sizeLevel: run.sizeLevel,
      children: ctx.tokenize(
        body,
        { ...ctx.innerOrigin, column: ctx.innerOrigin.column + run.bodyStart },
        false,
      ),
    })
  }

const markerMap = (specs: readonly NotationSpec[]): ReadonlyMap<string, string> =>
  new Map(specs.map((s) => [s.marker, s.name]))

export const buildExtension = (specs: readonly NotationSpec[]): Extension | undefined =>
  specs.length === 0 ? undefined : { bracketRules: [buildRule(markerMap(specs))] }

let currentSpecs: readonly NotationSpec[] = []
let markerToName: ReadonlyMap<string, string> = new Map()
let currentOptions: ParseOptions | undefined

/** Replaces the active notation set. Canonicalizes to marker-ascending order. */
export const setNotations = (specs: readonly NotationSpec[]): void => {
  currentSpecs = [...specs].sort((a, b) => (a.marker < b.marker ? -1 : a.marker > b.marker ? 1 : 0))
  markerToName = markerMap(currentSpecs)
  const extension = buildExtension(currentSpecs)
  currentOptions = extension ? { extensions: [extension] } : undefined
}

/** The options every `parse`/`parseLine` call must pass, so all features agree on notation. */
export const parseOptions = (): ParseOptions | undefined => currentOptions

/** Active specs, marker-ascending — the canonical order behind the semantic token legend. */
export const notationSpecs = (): readonly NotationSpec[] => currentSpecs

export const notationName = (marker: string): string | undefined => markerToName.get(marker)

/**
 * The user-defined notations a decoration node wears, in the order they were written —
 * empty for the official ones (`[* x]`, `[-_ x]`, `[[x]]`), whose markers are never
 * configurable.
 *
 * A run carries all of them at once, the way Cosense's own renderer emits one CSS class per
 * marker character and lets the stylesheet combine them.
 */
export const notationNamesForDecoration = (node: Decoration): readonly string[] => {
  const names: string[] = []
  for (const marker of node.markers) {
    const name = markerToName.get(marker)
    if (name !== undefined && !names.includes(name)) names.push(name)
  }
  return names
}

/** The notation that names the node: the first one written, or undefined for an official run. */
export const notationNameForDecoration = (node: Decoration): string | undefined =>
  notationNamesForDecoration(node)[0]
