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

/**
 * Line-level diff producing page-edit-for-ai RawChange ops (see docs/ARCHITECTURE.md and
 * cosense-cli src/commands/previewEdit.ts). A run of consecutive deletes/inserts between two
 * kept lines is paired up positionally into `_update`s (same line id, new text) first, with
 * any length difference becoming trailing `_delete`s or `_insert`s anchored on the next kept
 * line's id ('_end' when the run trails the whole document). Deterministic: ties in the LCS
 * backtrack always prefer consuming the base side (delete) first.
 */
export const computeChanges = (
  base: readonly BaseLine[],
  next: readonly string[],
  newLineId: () => string,
): readonly RawChange[] => {
  const ops = buildOps(base, next)
  const changes: RawChange[] = []
  let idx = 0

  while (idx < ops.length) {
    const op = ops[idx] as Op
    if (op.kind === 'match') {
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
    for (let k = 0; k < pairCount; k++) {
      changes.push({ _update: (dels[k] as BaseLine).id, lines: { text: inserts[k] as string } })
    }
    for (let k = pairCount; k < dels.length; k++) {
      changes.push({ _delete: (dels[k] as BaseLine).id })
    }
    for (let k = pairCount; k < inserts.length; k++) {
      changes.push({ _insert: anchor, lines: { id: newLineId(), text: inserts[k] as string } })
    }
  }

  return changes
}
