/**
 * asearch.ts — approximate string search (bitap / Shift-And, 浅見アルゴリズム port).
 *
 * `Asearch(pattern)` builds a matcher; `match(text, ambig)` tests whether `pattern`
 * approximately matches the *whole* of `text` within `ambig` errors (insertions,
 * deletions, substitutions) — this is an anchored match, not a substring search.
 * ASCII is case-insensitive; a halfwidth space in the pattern is epsilon (matches
 * anything, including nothing). 4 states (0..3 errors). Pure TS, no dependencies.
 *
 * Ported as-is (semantics preserved, not "improved") from the user's own prior art:
 * cosense-app-client/packages/domain/src/asearch.ts.
 */
const INITPAT = 0x80000000
const MAXCHAR = 0x10000
const INITSTATE: readonly [number, number, number, number] = [INITPAT, 0, 0, 0]

const isupper = (c: number): boolean => c >= 0x41 && c <= 0x5a
const islower = (c: number): boolean => c >= 0x61 && c <= 0x7a
const tolower = (c: number): number => (isupper(c) ? c + 0x20 : c)
const toupper = (c: number): number => (islower(c) ? c - 0x20 : c)

function unpack(str: string): number[] {
  const bytes: number[] = []
  for (const c of str.split('')) bytes.push(c.charCodeAt(0))
  return bytes
}

export type AsearchMatch = ((text: string, ambig?: number) => boolean) & { source: string }

export function Asearch(source: string): AsearchMatch {
  const shiftpat: number[] = new Array(MAXCHAR).fill(0)
  let epsilon = 0
  let mask = INITPAT
  for (const i of unpack(source)) {
    if (i === 0x20) {
      epsilon |= mask
    } else {
      shiftpat[i] = (shiftpat[i] ?? 0) | mask
      shiftpat[toupper(i)] = (shiftpat[toupper(i)] ?? 0) | mask
      shiftpat[tolower(i)] = (shiftpat[tolower(i)] ?? 0) | mask
      mask = mask >>> 1
    }
  }
  const acceptpat = mask

  function getState(
    state: readonly [number, number, number, number],
    str: string,
  ): [number, number, number, number] {
    let i0 = state[0]
    let i1 = state[1]
    let i2 = state[2]
    let i3 = state[3]
    for (const c of unpack(str)) {
      const m = shiftpat[c] ?? 0
      i3 = (i3 & epsilon) | ((i3 & m) >>> 1) | (i2 >>> 1) | i2
      i2 = (i2 & epsilon) | ((i2 & m) >>> 1) | (i1 >>> 1) | i1
      i1 = (i1 & epsilon) | ((i1 & m) >>> 1) | (i0 >>> 1) | i0
      i0 = (i0 & epsilon) | ((i0 & m) >>> 1)
      i1 |= i0 >>> 1
      i2 |= i1 >>> 1
      i3 |= i2 >>> 1
    }
    return [i0, i1, i2, i3]
  }

  const match = ((text: string, ambig = 0): boolean => {
    const state = getState(INITSTATE, text)
    const a = Math.max(0, Math.min(ambig, state.length - 1))
    return ((state[a] ?? 0) & acceptpat) !== 0
  }) as AsearchMatch
  match.source = source
  return match
}
