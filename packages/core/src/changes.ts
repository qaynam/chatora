import type { RawChange } from './types'

export interface BaseLine {
  readonly id: string
  readonly text: string
}

type Op =
  | { kind: 'match'; baseIndex: number; nextIndex: number }
  | { kind: 'del'; baseIndex: number }
  | { kind: 'ins'; nextIndex: number }

// Myers/LCS line diff over line text. dp[i][j] = LCS length of base[i..] and next[j..].
const buildOps = (base: readonly BaseLine[], next: readonly string[]): Op[] => {
  const n = base.length
  const m = next.length
  const dp: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0))
  for (let i = n - 1; i >= 0; i--) {
    const row = dp[i] as number[]
    const nextRow = dp[i + 1] as number[]
    for (let j = m - 1; j >= 0; j--) {
      row[j] =
        base[i]?.text === next[j]
          ? (nextRow[j + 1] as number) + 1
          : Math.max(nextRow[j] as number, row[j + 1] as number)
    }
  }

  const ops: Op[] = []
  let i = 0
  let j = 0
  while (i < n && j < m) {
    if (base[i]?.text === next[j]) {
      ops.push({ kind: 'match', baseIndex: i, nextIndex: j })
      i++
      j++
    } else if (((dp[i + 1] as number[])[j] as number) >= ((dp[i] as number[])[j + 1] as number)) {
      ops.push({ kind: 'del', baseIndex: i })
      i++
    } else {
      ops.push({ kind: 'ins', nextIndex: j })
      j++
    }
  }
  while (i < n) {
    ops.push({ kind: 'del', baseIndex: i })
    i++
  }
  while (j < m) {
    ops.push({ kind: 'ins', nextIndex: j })
    j++
  }
  return ops
}

/** A base line the edit left alone, text and id both. */
export interface KeptSegment {
  readonly kind: 'keep'
  readonly line: BaseLine
}

/**
 * One stretch of change between two kept lines. The deletes and inserts are paired up
 * positionally into `updates` first — same line id, new text — and whatever is left over
 * is a real deletion or a real insertion.
 */
export interface ChangedSegment {
  readonly kind: 'change'
  readonly updates: readonly { readonly line: BaseLine; readonly text: string }[]
  readonly deletes: readonly BaseLine[]
  readonly inserts: readonly string[]
  /** Base line id the inserts go *before*, or `'_end'` when the run trails the document. */
  readonly anchor: string
}

export type EditSegment = KeptSegment | ChangedSegment

/**
 * The edit turning `base` into `next`, as an ordered walk of the base document.
 *
 * This is the one place the local diff is interpreted, so a save and a merge always agree
 * on which base line a given piece of new text belongs to. Deterministic: ties in the LCS
 * backtrack always prefer consuming the base side (delete) first.
 */
export const buildSegments = (
  base: readonly BaseLine[],
  next: readonly string[],
): readonly EditSegment[] => {
  const ops = buildOps(base, next)
  const segments: EditSegment[] = []
  let idx = 0

  while (idx < ops.length) {
    const op = ops[idx] as Op
    if (op.kind === 'match') {
      segments.push({ kind: 'keep', line: base[op.baseIndex] as BaseLine })
      idx++
      continue
    }

    const dels: BaseLine[] = []
    const inserts: string[] = []
    while (idx < ops.length) {
      const current = ops[idx] as Op
      if (current.kind === 'del') {
        dels.push(base[current.baseIndex] as BaseLine)
        idx++
      } else if (current.kind === 'ins') {
        inserts.push(next[current.nextIndex] as string)
        idx++
      } else {
        break
      }
    }

    let anchor = '_end'
    for (let k = idx; k < ops.length; k++) {
      const candidate = ops[k] as Op
      if (candidate.kind === 'match') {
        anchor = (base[candidate.baseIndex] as BaseLine).id
        break
      }
    }

    const pairCount = Math.min(dels.length, inserts.length)
    segments.push({
      kind: 'change',
      updates: dels.slice(0, pairCount).map((line, k) => ({ line, text: inserts[k] as string })),
      deletes: dels.slice(pairCount),
      inserts: inserts.slice(pairCount),
      anchor,
    })
  }

  return segments
}

/**
 * For each line of `next`, the base line it is a copy of, or `undefined` where the edit
 * introduced it.
 *
 * Matching is by text, through the same LCS the save diff walks, so an edited line counts
 * as introduced: whatever the base line says about itself — who wrote it, when — stopped
 * being true of the text now sitting there.
 */
export const alignLines = <T extends BaseLine>(
  base: readonly T[],
  next: readonly string[],
): readonly (T | undefined)[] => {
  const aligned = new Array<T | undefined>(next.length).fill(undefined)
  for (const op of buildOps(base, next)) {
    if (op.kind === 'match') aligned[op.nextIndex] = base[op.baseIndex]
  }
  return aligned
}

/** Line-level diff producing page-edit-for-ai RawChange ops (cosense-cli src/commands/previewEdit.ts). */
export const computeChanges = (
  base: readonly BaseLine[],
  next: readonly string[],
  newLineId: () => string,
): readonly RawChange[] => {
  const changes: RawChange[] = []
  for (const segment of buildSegments(base, next)) {
    if (segment.kind === 'keep') continue
    for (const { line, text } of segment.updates)
      changes.push({ _update: line.id, lines: { text } })
    for (const line of segment.deletes) changes.push({ _delete: line.id })
    for (const text of segment.inserts) {
      changes.push({ _insert: segment.anchor, lines: { id: newLineId(), text } })
    }
  }
  return changes
}
