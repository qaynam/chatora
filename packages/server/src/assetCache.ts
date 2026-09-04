// What one session remembers about asset fetches that is not on disk: which URLs are being
// fetched right now, so a page of the same icon asks once, and which ones failed recently,
// so a picture that 404s is not asked for on every redraw.
import { Clock, Context, Deferred, Effect, Layer, Option, Ref, SynchronizedRef } from 'effect'
import type { FetchAssetResult } from './assets'
import type { ErrCode, ErrEnvelope } from './pages'

const err = (code: ErrCode, message: string): ErrEnvelope => ({ ok: false, code, message })
const UNAUTHORIZED_STATUSES: ReadonlySet<number> = new Set([401, 403])

export interface AssetCacheShape {
  /**
   * Runs `effect` for `key` at most once at a time: a second call for the same key while the
   * first is still in flight joins the first's result instead of starting its own fetch. A
   * page full of repeated icon notation for the same page name is the motivating case.
   */
  readonly dedupe: (
    key: string,
    effect: Effect.Effect<FetchAssetResult>,
  ) => Effect.Effect<FetchAssetResult>

  /**
   * The remembered failure for `key` while it is still cooling off, or none when the network
   * may be tried again.
   */
  readonly recallFailure: (key: string) => Effect.Effect<Option.Option<FetchAssetResult>>

  /** Remember that `key` failed, and hold off the next attempt for longer than the last. */
  readonly noteFailure: (key: string, status: number, wait?: number) => Effect.Effect<void>

  /** Forget `key`'s failures — it answered. */
  readonly noteSuccess: (key: string) => Effect.Effect<void>
}

/**
 * How long a failed asset waits before it is fetched again, per attempt. Only successes are
 * cached, so without this a picture that 404s is re-requested on every redraw — measured at
 * 69 requests for one deleted image, and 24 rate-limited ones for a GitHub preview that had
 * already said no. After the last of these the URL is left alone for the session.
 */
const FAILURE_BACKOFF_MS = [30_000, 120_000, 600_000] as const

interface FailureRecord {
  readonly attempts: number
  /** Epoch ms before which nothing is sent; `Infinity` once the attempts are spent. */
  readonly until: number
  readonly status: number
}

export class AssetCache extends Context.Tag('@chatora/server/AssetCache')<
  AssetCache,
  AssetCacheShape
>() {}

interface PendingLookup {
  readonly deferred: Deferred.Deferred<FetchAssetResult>
  readonly isNew: boolean
}

export const AssetCacheLive: Layer.Layer<AssetCache> = Layer.effect(
  AssetCache,
  Effect.gen(function* () {
    const pendingRef = yield* SynchronizedRef.make<
      ReadonlyMap<string, Deferred.Deferred<FetchAssetResult>>
    >(new Map())
    const failuresRef = yield* Ref.make<ReadonlyMap<string, FailureRecord>>(new Map())

    const recallFailure: AssetCacheShape['recallFailure'] = (key) =>
      Effect.gen(function* () {
        const record = (yield* Ref.get(failuresRef)).get(key)
        if (record === undefined) return Option.none()
        const now = yield* Clock.currentTimeMillis
        if (now >= record.until) return Option.none()
        return Option.some(
          UNAUTHORIZED_STATUSES.has(record.status)
            ? err('unauthorized', 'authentication failed')
            : err('error', `HTTP ${record.status}`),
        )
      })

    const noteFailure: AssetCacheShape['noteFailure'] = (key, status, wait) =>
      Effect.gen(function* () {
        const now = yield* Clock.currentTimeMillis
        const attempts = ((yield* Ref.get(failuresRef)).get(key)?.attempts ?? 0) + 1
        const backoff = FAILURE_BACKOFF_MS[attempts - 1]
        // A server that named its own wait gets it, but never less than our own step: the
        // point is to stop asking, not to obey a `Retry-After: 1`.
        const until =
          backoff === undefined ? Number.POSITIVE_INFINITY : now + Math.max(backoff, wait ?? 0)
        yield* Ref.update(failuresRef, (map) => new Map(map).set(key, { attempts, until, status }))
      })

    const noteSuccess: AssetCacheShape['noteSuccess'] = (key) =>
      Ref.update(failuresRef, (map) => {
        if (!map.has(key)) return map
        const next = new Map(map)
        next.delete(key)
        return next
      })

    const dedupe: AssetCacheShape['dedupe'] = (key, effect) =>
      Effect.gen(function* () {
        // SynchronizedRef serializes this read-or-register step, so two callers racing on the
        // same key can never both conclude "I'm first" and start two fetches.
        const { deferred, isNew } = yield* SynchronizedRef.modifyEffect(
          pendingRef,
          (
            pending,
          ): Effect.Effect<
            readonly [PendingLookup, ReadonlyMap<string, Deferred.Deferred<FetchAssetResult>>]
          > => {
            const existing = pending.get(key)
            if (existing !== undefined) {
              return Effect.succeed([{ deferred: existing, isNew: false }, pending])
            }
            return Deferred.make<FetchAssetResult>().pipe(
              Effect.map((fresh) => [
                { deferred: fresh, isNew: true },
                new Map(pending).set(key, fresh),
              ]),
            )
          },
        )

        if (isNew) {
          yield* effect.pipe(
            Effect.exit,
            Effect.flatMap((exit) => Deferred.done(deferred, exit)),
            Effect.zipRight(
              SynchronizedRef.update(pendingRef, (pending) => {
                if (!pending.has(key)) return pending
                const next = new Map(pending)
                next.delete(key)
                return next
              }),
            ),
            Effect.forkDaemon,
          )
        }

        return yield* Deferred.await(deferred)
      })

    return AssetCache.of({ dedupe, recallFailure, noteFailure, noteSuccess })
  }),
)
