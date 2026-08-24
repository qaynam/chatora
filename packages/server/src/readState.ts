import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import { stateFilePath } from '@chatora/core'
import { Clock, Context, Effect, Layer, Ref } from 'effect'

/**
 * When each page was last opened in chatora, per project.
 *
 * Cosense's own `accessed` field is the authority for this, but nothing chatora can call
 * updates it: `/api/pages/:project/:pageId/accessed` answers 404 (observed in cosense-app-client's
 * own request logs, on cookie auth), and the real client records reads over its websocket
 * commit channel. Until that channel exists here, opening a page has to be remembered locally
 * or the unread mark would come straight back on the next poll.
 */
export interface ReadStateShape {
  /** Unix seconds of the local visit to `pageId`, or 0 if never opened here. */
  readonly readAt: (project: string, pageId: string) => Effect.Effect<number>
  readonly markRead: (project: string, pageId: string) => Effect.Effect<void>
}

export class ReadState extends Context.Tag('@chatora/server/ReadState')<
  ReadState,
  ReadStateShape
>() {}

type Store = Record<string, Record<string, number>>

const filePath = (): string => stateFilePath('read.json')

const parse = (text: string): Store => {
  try {
    const parsed: unknown = JSON.parse(text)
    if (typeof parsed !== 'object' || parsed === null) return {}
    const out: Store = {}
    for (const [project, pages] of Object.entries(parsed as Record<string, unknown>)) {
      if (typeof pages !== 'object' || pages === null) continue
      const entries: Record<string, number> = {}
      for (const [pageId, at] of Object.entries(pages as Record<string, unknown>)) {
        if (typeof at === 'number' && Number.isFinite(at)) entries[pageId] = at
      }
      out[project] = entries
    }
    return out
  } catch {
    return {}
  }
}

export const ReadStateLive: Layer.Layer<ReadState> = Layer.effect(
  ReadState,
  Effect.gen(function* () {
    // Read once and kept in memory: this is consulted for every row of every page listing.
    const loaded = yield* Effect.tryPromise(() => readFile(filePath(), 'utf8')).pipe(
      Effect.map(parse),
      Effect.orElseSucceed((): Store => ({})),
    )
    const ref = yield* Ref.make(loaded)

    const persist = (store: Store): Effect.Effect<void> =>
      Effect.tryPromise(async () => {
        const path = filePath()
        await mkdir(dirname(path), { recursive: true })
        await writeFile(path, JSON.stringify(store))
      }).pipe(Effect.ignore)

    return ReadState.of({
      readAt: (project, pageId) =>
        Effect.map(Ref.get(ref), (store) => store[project]?.[pageId] ?? 0),
      markRead: (project, pageId) =>
        Effect.gen(function* () {
          const now = Math.floor((yield* Clock.currentTimeMillis) / 1000)
          const store = yield* Ref.updateAndGet(ref, (current) => ({
            ...current,
            [project]: { ...(current[project] ?? {}), [pageId]: now },
          }))
          yield* persist(store)
        }),
    })
  }),
)
