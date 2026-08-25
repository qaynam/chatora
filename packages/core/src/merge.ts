import { type BaseLine, buildSegments } from './changes'

/**
 * A line both sides changed, kept in the merged text as whatever protects the local edit.
 *
 * `line` indexes into `merged`, so the client can mark it. `theirs` is null when the server
 * deleted the line; `ours` is null when the local edit was the deletion.
 */
export interface MergeConflict {
  readonly line: number
  readonly ours: string | null
  readonly theirs: string | null
  readonly base: string
}

export interface MergeResult {
  readonly merged: readonly string[]
  readonly conflicts: readonly MergeConflict[]
}

/**
 * Merge the server's current lines into a locally edited buffer.
 *
 * `base` is the server state the local edits were made against, `ours` the buffer as it
 * stands, `theirs` what the server holds now. The local side is attributed to base line ids
 * by the same diff a save uses; the remote side needs no diff at all, since its lines carry
 * the ids `base` already has — an id missing from `theirs` was deleted on the server, and an
 * id absent from `base` was added there.
 *
 * The invariant is that **no locally written text is ever dropped**. Where the two sides
 * disagree the local text stays and the line is reported as a conflict, and a line the
 * server deleted out from under a local edit is re-inserted rather than lost. The one thing
 * that does not survive is a purely local *deletion* of a line the server went on to edit:
 * the server's text comes back, flagged, because a deletion is recoverable by deleting
 * again and text that never appears is not.
 */
export const mergeThreeWay = (
  base: readonly BaseLine[],
  ours: readonly string[],
  theirs: readonly BaseLine[],
): MergeResult => {
  const baseText = new Map(base.map((line) => [line.id, line.text]))
  const baseOrder = new Map(base.map((line, index) => [line.id, index]))
  const survives = new Set(theirs.map((line) => line.id))

  // What the local edits did to each base line, and where new local text belongs.
  type Local = { readonly kind: 'update' | 'delete'; readonly text: string }
  const local = new Map<string, Local>()
  const insertsByAnchor = new Map<string, string[]>()
  const addInserts = (anchor: string, texts: readonly string[]) => {
    if (texts.length === 0) return
    const existing = insertsByAnchor.get(anchor)
    if (existing) existing.push(...texts)
    else insertsByAnchor.set(anchor, [...texts])
  }

  for (const segment of buildSegments(base, ours)) {
    if (segment.kind === 'keep') continue
    for (const { line, text } of segment.updates) local.set(line.id, { kind: 'update', text })
    for (const line of segment.deletes) local.set(line.id, { kind: 'delete', text: line.text })
    addInserts(segment.anchor, segment.inserts)
  }

  // An anchor the server deleted cannot be flushed against `theirs`, so move each such run
  // forward to the first base line that is still there. Nothing is dropped; new text lands
  // as close to where it was written as the remote document still allows.
  const resolveAnchor = (anchor: string): string => {
    if (anchor === '_end' || survives.has(anchor)) return anchor
    for (let i = (baseOrder.get(anchor) ?? base.length) + 1; i < base.length; i++) {
      const id = (base[i] as BaseLine).id
      if (survives.has(id)) return id
    }
    return '_end'
  }
  const pending = new Map<string, string[]>()
  for (const [anchor, texts] of [...insertsByAnchor].sort(
    (a, b) => (baseOrder.get(a[0]) ?? base.length) - (baseOrder.get(b[0]) ?? base.length),
  )) {
    const resolved = resolveAnchor(anchor)
    const existing = pending.get(resolved)
    if (existing) existing.push(...texts)
    else pending.set(resolved, [...texts])
  }

  // A line edited locally that the server has since deleted would otherwise vanish with it.
  // It is re-inserted where its anchor now points, as a conflict rather than a silent save.
  const rescued = new Map<string, { readonly text: string; readonly base: string }[]>()
  for (const [id, edit] of local) {
    if (edit.kind !== 'update' || survives.has(id)) continue
    const anchor = resolveAnchor(id)
    const entry = { text: edit.text, base: baseText.get(id) ?? '' }
    const existing = rescued.get(anchor)
    if (existing) existing.push(entry)
    else rescued.set(anchor, [entry])
  }

  const merged: string[] = []
  const conflicts: MergeConflict[] = []
  const flush = (anchor: string) => {
    for (const { text, base: was } of rescued.get(anchor) ?? []) {
      conflicts.push({ line: merged.length, ours: text, theirs: null, base: was })
      merged.push(text)
    }
    for (const text of pending.get(anchor) ?? []) merged.push(text)
  }

  for (const line of theirs) {
    flush(line.id)
    const was = baseText.get(line.id)
    if (was === undefined) {
      merged.push(line.text)
      continue
    }
    const edit = local.get(line.id)
    const remoteChanged = line.text !== was
    if (edit === undefined) {
      merged.push(line.text)
      continue
    }
    if (edit.kind === 'delete') {
      if (!remoteChanged) continue
      conflicts.push({ line: merged.length, ours: null, theirs: line.text, base: was })
      merged.push(line.text)
      continue
    }
    if (!remoteChanged || line.text === edit.text) {
      merged.push(edit.text)
      continue
    }
    conflicts.push({ line: merged.length, ours: edit.text, theirs: line.text, base: was })
    merged.push(edit.text)
  }
  flush('_end')

  return { merged, conflicts }
}
