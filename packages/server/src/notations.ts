import type { Extension, ParseOptions } from '@cosense-toolbox/parser'
import { Option } from 'effect'

/** One user-defined `[<marker> body]` notation, wired to a semantic token type named `name`. */
export interface NotationSpec {
  readonly marker: string
  readonly name: string
}

// Not part of the package's public exports (only Extension is) — recovered from its shape.
type BracketRule = NonNullable<Extension['bracketRules']>[number]

const WHITESPACE_RE = /\s/

const buildRule =
  (spec: NotationSpec): BracketRule =>
  (inner, ctx) => {
    if (!inner.startsWith(spec.marker)) return Option.none()
    let end = spec.marker.length
    while (end < inner.length && WHITESPACE_RE.test(inner[end] as string)) end++
    if (end === spec.marker.length) return Option.none()
    const body = inner.slice(end)
    if (body === '') return Option.none()
    return Option.some({
      type: 'decoration',
      value: body,
      bold: false,
      italic: false,
      strike: false,
      underline: false,
      sizeLevel: 0,
      children: ctx.tokenize(
        body,
        { ...ctx.innerOrigin, column: ctx.innerOrigin.column + end },
        false,
      ),
    })
  }

export const buildExtension = (specs: readonly NotationSpec[]): Extension | undefined =>
  specs.length === 0 ? undefined : { bracketRules: specs.map(buildRule) }

let currentSpecs: readonly NotationSpec[] = []
let markerToName: ReadonlyMap<string, string> = new Map()
let currentOptions: ParseOptions | undefined

/** Replaces the active notation set. Canonicalizes to marker-ascending order. */
export const setNotations = (specs: readonly NotationSpec[]): void => {
  currentSpecs = [...specs].sort((a, b) => (a.marker < b.marker ? -1 : a.marker > b.marker ? 1 : 0))
  markerToName = new Map(currentSpecs.map((s) => [s.marker, s.name]))
  const extension = buildExtension(currentSpecs)
  currentOptions = extension ? { extensions: [extension] } : undefined
}

/** The options every `parse`/`parseLine` call must pass, so all features agree on notation. */
export const parseOptions = (): ParseOptions | undefined => currentOptions

/** Active specs, marker-ascending — the canonical order behind the semantic token legend. */
export const notationSpecs = (): readonly NotationSpec[] => currentSpecs

export const notationName = (marker: string): string | undefined => markerToName.get(marker)
