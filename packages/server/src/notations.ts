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

interface MarkerRun {
  /** Name of the first user-defined notation in the run. */
  readonly notation: string
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
  let notation: string | undefined
  let asterisks = 0
  let end = 0
  for (; end < inner.length; end++) {
    const char = inner[end] as string
    const official = OFFICIAL_MARKERS[char as keyof typeof OFFICIAL_MARKERS]
    if (official !== undefined) {
      flags[official] = true
      if (char === '*') asterisks++
      continue
    }
    const name = markers.get(char)
    if (name === undefined) break
    notation ??= name
  }
  if (notation === undefined) return undefined

  let bodyStart = end
  while (bodyStart < inner.length && WHITESPACE_RE.test(inner[bodyStart] as string)) bodyStart++
  if (bodyStart === end || bodyStart === inner.length) return undefined

  return {
    notation,
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
 * Which user-defined notation (if any) opened a given decoration node — undefined for
 * the official ones (`[* x]`, `[-_ x]`, `[[x]]`).
 *
 * @remarks
 * The AST keeps only the resulting style flags, so the marker run is rescanned from the
 * source with the same function that matched it: whatever the parse accepted, this
 * agrees with.
 */
export const notationNameForDecoration = (
  node: Decoration,
  docLines: readonly string[],
): string | undefined => {
  const line = docLines[node.position.start.line]
  if (line === undefined) return undefined
  const inner = line.slice(node.position.start.column + 1, node.position.end.column - 1)
  return scanMarkerRun(inner, markerToName)?.notation
}
