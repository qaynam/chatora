import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import type { TitleEntry } from '@chatora/core'
import { stateFilePath } from '@chatora/core'
import { Effect } from 'effect'

/**
 * The project's page titles, kept on disk between sessions.
 *
 * The index is what decides whether a link points at a page that exists, and it is large —
 * a few thousand titles is half a megabyte. Holding it only in memory means paying for all
 * of it again every time Neovim starts, before any link on the first page opened can be
 * judged. The browser client keeps the same list in its Cache API for the same reason.
 *
 * Staleness is the caller's business: this stores when the list was written and hands that
 * back, so `SessionState` applies one rule to the memory copy and this one alike.
 */
export interface StoredTitles {
  readonly fetchedAt: number
  readonly titles: readonly TitleEntry[]
}

const filePath = (project: string): string =>
  stateFilePath(`titles/${encodeURIComponent(project)}.json`)

const isEntry = (value: unknown): value is TitleEntry =>
  typeof value === 'object' &&
  value !== null &&
  typeof (value as TitleEntry).title === 'string' &&
  typeof (value as TitleEntry).id === 'string'

/** The stored list for `project`, or undefined when there is none or it cannot be read. */
export const loadTitles = (project: string): Effect.Effect<StoredTitles | undefined> =>
  Effect.tryPromise(async () => {
    const parsed: unknown = JSON.parse(await readFile(filePath(project), 'utf8'))
    if (typeof parsed !== 'object' || parsed === null) return undefined
    const { fetchedAt, titles } = parsed as { fetchedAt?: unknown; titles?: unknown }
    if (typeof fetchedAt !== 'number' || !Array.isArray(titles)) return undefined
    return { fetchedAt, titles: titles.filter(isEntry) }
  }).pipe(Effect.orElseSucceed(() => undefined))

/** Best-effort: a cache that cannot be written is a slower start, not a failure. */
export const saveTitles = (project: string, stored: StoredTitles): Effect.Effect<void> =>
  Effect.tryPromise(async () => {
    const path = filePath(project)
    await mkdir(dirname(path), { recursive: true })
    await writeFile(path, JSON.stringify(stored))
  }).pipe(Effect.catchAll(() => Effect.void))
