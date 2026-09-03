import { execFile } from 'node:child_process'
import { createHash, randomBytes } from 'node:crypto'
import { mkdir, open, readdir, rename, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import type { Credential, HttpClientShape } from '@chatora/core'
import { HttpClient } from '@chatora/core'
import { Clock, Context, Data, Deferred, Effect, Layer, Option, Ref, SynchronizedRef } from 'effect'
import { resolveGyazo } from './gyazo'
import { imageSizeOf } from './imageSize'
import { log } from './log'
import type { ErrCode, ErrEnvelope } from './pages'
import { SessionState } from './state'

const err = (code: ErrCode, message: string): ErrEnvelope => ({ ok: false, code, message })
const UNAUTHORIZED_STATUSES: ReadonlySet<number> = new Set([401, 403])

export interface FetchAssetSuccess {
  readonly ok: true
  readonly path: string
  /** Intrinsic pixel size of the file at `path`; absent when the format is unmeasurable. */
  readonly width?: number
  readonly height?: number
}
export type FetchAssetResult = FetchAssetSuccess | ErrEnvelope

/**
 * `status` mirrors CosenseApiError's convention: the real HTTP status for a non-2xx final
 * response, or `0` for a failure below the HTTP layer (transport, redirect-limit, disk I/O).
 * `message` is always safe to forward to the client — it never includes a header value.
 */
class AssetFetchError extends Data.TaggedError('AssetFetchError')<{
  readonly status: number
  readonly message: string
  /** From `Retry-After`, when the server named a wait of its own (429 and 503 do). */
  readonly retryAfterMs?: number
}> {}

/** `Retry-After` is either a number of seconds or an HTTP date; both are worth honouring. */
const retryAfterMs = (header: string | null): number | undefined => {
  if (header === null) return undefined
  const seconds = Number(header)
  if (Number.isFinite(seconds)) return Math.max(0, seconds * 1000)
  const at = Date.parse(header)
  return Number.isNaN(at) ? undefined : Math.max(0, at - Date.now())
}

// ---------------------------------------------------------------------------
// cache directory + on-disk lookup
// ---------------------------------------------------------------------------

/**
 * `$XDG_CACHE_HOME/chatora/assets`, falling back to `~/.cache/chatora/assets`.
 * `CHATORA_CACHE_DIR` overrides the whole path when set, so tests can point the cache at a
 * throwaway temp directory instead of touching the real home directory.
 */
const resolveCacheDir = (): string => {
  const override = process.env.CHATORA_CACHE_DIR
  if (override !== undefined && override !== '') return override
  const xdgCacheHome = process.env.XDG_CACHE_HOME
  const base =
    xdgCacheHome !== undefined && xdgCacheHome !== '' ? xdgCacheHome : join(homedir(), '.cache')
  return join(base, 'chatora', 'assets')
}

/** First 32 hex chars of sha256(url) — enough to make collisions a non-concern for a local icon/image cache. */
const cacheKey = (url: string): string =>
  createHash('sha256').update(url).digest('hex').slice(0, 32)

const CONTENT_TYPE_EXTENSIONS: Readonly<Record<string, string>> = {
  'image/png': '.png',
  'image/jpeg': '.jpg',
  'image/jpg': '.jpg',
  'image/gif': '.gif',
  'image/webp': '.webp',
  'image/svg+xml': '.svg',
}
const FALLBACK_EXTENSION = '.img'

// snacks.nvim sniffs image content itself, so an unrecognized content-type isn't fatal —
// '.img' just keeps the cache file's name meaningful without guessing wrong.
const extensionFor = (contentType: string | null): string => {
  if (contentType === null) return FALLBACK_EXTENSION
  const mime = contentType.split(';', 1)[0]?.trim().toLowerCase() ?? ''
  return CONTENT_TYPE_EXTENSIONS[mime] ?? FALLBACK_EXTENSION
}

/**
 * Any file already on disk for this hash, regardless of which extension it was written with —
 * a cache hit skips the network entirely, since icons rarely change (a future refresh command
 * can invalidate by deleting the cache directory).
 */
const findCached = (cacheDir: string, hash: string): Effect.Effect<Option.Option<string>> =>
  Effect.tryPromise(() => readdir(cacheDir)).pipe(
    Effect.map((names) => names.find((name) => name.startsWith(hash))),
    Effect.map((name) => (name === undefined ? Option.none() : Option.some(join(cacheDir, name)))),
    // readdir fails with ENOENT before the cache directory has ever been created; either way
    // that just means "not cached yet".
    Effect.orElseSucceed(() => Option.none<string>()),
  )

const writeAtomic = (
  cacheDir: string,
  hash: string,
  ext: string,
  body: Uint8Array,
): Effect.Effect<string, AssetFetchError> =>
  Effect.gen(function* () {
    yield* Effect.tryPromise(() => mkdir(cacheDir, { recursive: true })).pipe(
      Effect.mapError(
        () => new AssetFetchError({ status: 0, message: 'failed to create asset cache directory' }),
      ),
    )
    const finalPath = join(cacheDir, `${hash}${ext}`)
    // Write-then-rename: a concurrent reader (snacks placing the previous refresh's image)
    // never observes a partially-written file at the final path.
    const tmpPath = join(cacheDir, `.${hash}${ext}.${randomBytes(4).toString('hex')}.tmp`)
    yield* Effect.tryPromise(() => writeFile(tmpPath, body)).pipe(
      Effect.mapError(
        () => new AssetFetchError({ status: 0, message: 'failed to write cached asset' }),
      ),
    )
    yield* Effect.tryPromise(() => rename(tmpPath, finalPath)).pipe(
      Effect.mapError(
        () => new AssetFetchError({ status: 0, message: 'failed to finalize cached asset' }),
      ),
    )
    return finalPath
  })

// ---------------------------------------------------------------------------
// credential-scoped fetch with manual redirects
// ---------------------------------------------------------------------------

// Credential headers must never follow a redirect off the origin (cosense-cli's own
// file-download path does not forward them either); the icon endpoint specifically 302s
// to GCS, which is the case this whole manual-redirect walk exists for.
const MAX_REDIRECTS = 3
const isRedirectStatus = (status: number): boolean => status >= 300 && status < 400

const buildCredentialHeaders = (credential: Credential): Record<string, string> =>
  credential.type === 'serviceAccount'
    ? { 'x-service-account-access-key': credential.value }
    : { 'x-personal-access-token': credential.value }

const isFetchableUrl = (url: string): boolean => {
  try {
    const { protocol } = new URL(url)
    return protocol === 'http:' || protocol === 'https:'
  } catch {
    return false
  }
}

const originOf = (url: string): string | null => {
  try {
    return new URL(url).origin
  } catch {
    return null
  }
}

/** Recomputed at every hop from the *current* URL, so the header is dropped the instant a redirect leaves the session origin (and never re-attached if it somehow returns). */
const headersForUrl =
  (sessionOrigin: string, credential: Option.Option<Credential>) =>
  (url: string): Record<string, string> =>
    Option.isSome(credential) && originOf(url) === originOf(sessionOrigin)
      ? buildCredentialHeaders(credential.value)
      : {}

const fetchFollowingRedirects = (
  fetch: HttpClientShape['fetch'],
  headersFor: (url: string) => Record<string, string>,
  startUrl: string,
): Effect.Effect<Response, AssetFetchError> =>
  Effect.gen(function* () {
    let url = startUrl
    for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
      const response = yield* fetch(url, { headers: headersFor(url), redirect: 'manual' }).pipe(
        Effect.mapError(
          (error) =>
            new AssetFetchError({ status: 0, message: `fetch failed: ${String(error.cause)}` }),
        ),
      )
      if (!isRedirectStatus(response.status)) return response
      if (hop === MAX_REDIRECTS) {
        return yield* Effect.fail(new AssetFetchError({ status: 0, message: 'too many redirects' }))
      }
      const location = response.headers.get('location')
      if (location === null) return response // nothing to follow; the non-2xx check below reports it
      url = new URL(location, url).toString()
    }
    return yield* Effect.fail(new AssetFetchError({ status: 0, message: 'too many redirects' }))
  })

const fromAssetFetchError = (error: AssetFetchError): ErrEnvelope =>
  UNAUTHORIZED_STATUSES.has(error.status)
    ? err('unauthorized', 'authentication failed')
    : err('error', error.message)

const fetchAndCache = (
  fetch: HttpClientShape['fetch'],
  headersFor: (url: string) => Record<string, string>,
  cacheDir: string,
  hash: string,
  url: string,
  onFailure: (status: number, retryAfterMs?: number) => Effect.Effect<void>,
): Effect.Effect<FetchAssetResult> =>
  Effect.gen(function* () {
    const response = yield* fetchFollowingRedirects(fetch, headersFor, url)
    if (!response.ok) {
      const wait = retryAfterMs(response.headers.get('retry-after'))
      return yield* Effect.fail(
        new AssetFetchError({
          status: response.status,
          message: `HTTP ${response.status} ${response.statusText}`.trim(),
          ...(wait === undefined ? {} : { retryAfterMs: wait }),
        }),
      )
    }
    const body = yield* Effect.tryPromise(() => response.arrayBuffer()).pipe(
      Effect.mapError(
        () => new AssetFetchError({ status: 0, message: 'failed to read response body' }),
      ),
    )
    const ext = extensionFor(response.headers.get('content-type'))
    const path = yield* writeAtomic(cacheDir, hash, ext, new Uint8Array(body))
    return { ok: true as const, path }
  }).pipe(
    // A failed asset is deliberately silent in the UI, since a missing picture is
    // cosmetic — which is exactly why it is worth recording somewhere.
    Effect.tapError((error) =>
      log('warn', 'asset fetch failed', { url, status: error.status, detail: error.message }).pipe(
        Effect.zipRight(onFailure(error.status, error.retryAfterMs)),
      ),
    ),
    Effect.catchTag('AssetFetchError', (error) => Effect.succeed(fromAssetFetchError(error))),
  )

// ---------------------------------------------------------------------------
// border compositing
// ---------------------------------------------------------------------------

export interface BorderParams {
  readonly width: number
  readonly color: string
  readonly padding: number
}

const execFileAsync = promisify(execFile)

// Everything reaching an ImageMagick argv goes through these. A rejected value came from
// user config, so the whole border is skipped rather than guessed at.
const clampPx = (value: unknown, fallback: number): number => {
  const n = typeof value === 'number' && Number.isFinite(value) ? Math.floor(value) : fallback
  return Math.min(64, Math.max(0, n))
}
const COLOR_RE = /^(#[0-9a-fA-F]{3,8}|[a-zA-Z]+)$/

const sanitizeBorder = (border: BorderParams): BorderParams | null => {
  if (!COLOR_RE.test(border.color)) return null
  const width = clampPx(border.width, 1)
  const padding = clampPx(border.padding, 12)
  if (width === 0 && padding === 0) return null
  return { width, color: border.color, padding }
}

/**
 * Builds a resolver that returns the first of `candidates` whose command answers
 * `versionFlag`, or `null` when none is installed.
 *
 * @remarks
 * The verdict is memoized for the life of the process, so a missing tool costs one failed
 * spawn overall rather than one per request. A tool installed after startup is not picked
 * up until the server restarts.
 */
const firstAvailable = <T extends { readonly cmd: string }>(
  candidates: readonly T[],
  versionFlag: string,
): (() => Promise<T | null>) => {
  let resolved: T | null | undefined
  return async () => {
    if (resolved !== undefined) return resolved
    for (const candidate of candidates) {
      try {
        await execFileAsync(candidate.cmd, [versionFlag])
        resolved = candidate
        return candidate
      } catch {}
    }
    resolved = null
    return null
  }
}

/**
 * ImageMagick 7 ships `magick`; some installs only have the IM6 `convert`. `null` (no
 * ImageMagick at all) disables compositing.
 */
const resolveMagick = firstAvailable([{ cmd: 'magick' }, { cmd: 'convert' }], '-version')

/**
 * Composites a frame into the image itself — a transparent padding ring, then the border
 * line — since a terminal can only frame an image by baking it into the pixels. The cache
 * name is *prefixed* with the params hash so the plain `findCached(hash)` prefix lookup can
 * never pick up a bordered variant. Falls back to the original path when ImageMagick is
 * missing or the composite fails: the border is cosmetic, the image is not.
 */
const withBorder = (
  cacheDir: string,
  hash: string,
  sourcePath: string,
  border: BorderParams,
): Effect.Effect<string> =>
  Effect.gen(function* () {
    const paramsHash = cacheKey(`${border.width}\0${border.color}\0${border.padding}`).slice(0, 8)
    const borderedName = `b${paramsHash}-${hash}`
    const borderedPath = join(cacheDir, `${borderedName}.png`)
    const existing = yield* findCached(cacheDir, borderedName)
    if (Option.isSome(existing)) return existing.value

    const magick = yield* Effect.promise(resolveMagick)
    if (magick === null) return sourcePath

    // -compose copy on the second -border: without it, IM floods the border
    // color through the transparent padding ring instead of only framing it.
    const args = [
      sourcePath,
      '-alpha',
      'set',
      '-bordercolor',
      'none',
      '-border',
      String(border.padding),
      '-compose',
      'copy',
      '-bordercolor',
      border.color,
      '-border',
      String(border.width),
      borderedPath,
    ]
    return yield* Effect.tryPromise(() => execFileAsync(magick.cmd, args)).pipe(
      Effect.as(borderedPath),
      Effect.orElseSucceed(() => sourcePath),
    )
  })

const applyBorder = (
  cacheDir: string,
  hash: string,
  result: FetchAssetResult,
  border: BorderParams | null,
): Effect.Effect<FetchAssetResult> => {
  if (border === null || !result.ok) return Effect.succeed(result)
  return Effect.map(withBorder(cacheDir, hash, result.path, border), (path) => ({
    ok: true as const,
    path,
  }))
}

// ---------------------------------------------------------------------------
// SVG rasterization
// ---------------------------------------------------------------------------

const RASTER_DPI = '192'

/**
 * SVG rasterizers, best first. librsvg is what ImageMagick itself delegates to when present;
 * without it ImageMagick falls back to its own renderer, which cannot resolve fonts and so
 * fails outright on any SVG containing text.
 */
const RASTERIZERS: readonly {
  readonly cmd: string
  readonly args: (i: string, o: string) => string[]
}[] = [
  {
    cmd: 'rsvg-convert',
    args: (i, o) => ['--dpi-x', RASTER_DPI, '--dpi-y', RASTER_DPI, '-o', o, i],
  },
  // -density must precede the input: SVG has no pixel size, and the default 72 DPI is blurry.
  { cmd: 'magick', args: (i, o) => ['-density', RASTER_DPI, '-background', 'none', i, o] },
  { cmd: 'convert', args: (i, o) => ['-density', RASTER_DPI, '-background', 'none', i, o] },
]

const resolveRasterizer = firstAvailable(RASTERIZERS, '--version')

/**
 * Terminal graphics protocols composite raster formats only, so an `image/svg+xml` asset is
 * unusable as-is. Cached under an `r`-prefixed name — same reasoning as `withBorder`'s `b`
 * prefix: it must never collide with the plain `findCached(hash)` lookup for the `.svg`.
 * `Option.none` means the SVG could not be rasterized and there is nothing to display.
 */
const rasterizeSvg = (
  cacheDir: string,
  hash: string,
  svgPath: string,
): Effect.Effect<Option.Option<string>> =>
  Effect.gen(function* () {
    const rasterName = `r${hash}`
    const rasterPath = join(cacheDir, `${rasterName}.png`)
    const existing = yield* findCached(cacheDir, rasterName)
    if (Option.isSome(existing)) return existing

    const tool = yield* Effect.promise(resolveRasterizer)
    if (tool === null) return Option.none()

    return yield* Effect.tryPromise(() =>
      execFileAsync(tool.cmd, tool.args(svgPath, rasterPath)),
    ).pipe(
      Effect.as(Option.some(rasterPath)),
      Effect.orElseSucceed(() => Option.none<string>()),
    )
  })

/**
 * The first frame of a GIF, as a PNG.
 *
 * A terminal graphics protocol composites stills, and neither render backend animates. The
 * catch is that ImageMagick writes *one file per frame* unless a frame is named: converting
 * `a.gif` yields `a-0.png`, `a-1.png`… and never the path it was handed, so frame 0 is named.
 *
 * Cached under a `g`-prefixed name, for the same reason the rasterized SVG is: it must never
 * be picked up by the plain `findCached(hash)` lookup for the `.gif` itself.
 */
const flattenGif = (
  cacheDir: string,
  hash: string,
  gifPath: string,
): Effect.Effect<Option.Option<string>> =>
  Effect.gen(function* () {
    const frameName = `g${hash}`
    const framePath = join(cacheDir, `${frameName}.png`)
    const existing = yield* findCached(cacheDir, frameName)
    if (Option.isSome(existing)) return existing

    const magick = yield* Effect.promise(resolveMagick)
    if (magick === null) return Option.none()

    return yield* Effect.tryPromise(() =>
      execFileAsync(magick.cmd, [`${gifPath}[0]`, framePath]),
    ).pipe(
      Effect.as(Option.some(framePath)),
      Effect.orElseSucceed(() => Option.none<string>()),
    )
  })

/**
 * Unlike an SVG, a GIF that cannot be flattened is still worth handing over: a single-frame
 * one draws as it is, and a backend of its own accord may name the frame too.
 */
const applyGifFrame = (
  cacheDir: string,
  hash: string,
  result: FetchAssetResult,
): Effect.Effect<FetchAssetResult> => {
  if (!result.ok || !result.path.endsWith('.gif')) return Effect.succeed(result)
  return Effect.map(flattenGif(cacheDir, hash, result.path), (frame) =>
    Option.match(frame, {
      onNone: (): FetchAssetResult => result,
      onSome: (path): FetchAssetResult => ({ ok: true as const, path }),
    }),
  )
}

const SVG_HELP =
  'SVG を画像に変換できませんでした。`brew install librsvg` で表示できるようになります'

const applySvgRaster = (
  cacheDir: string,
  hash: string,
  result: FetchAssetResult,
): Effect.Effect<FetchAssetResult> => {
  if (!result.ok || !result.path.endsWith('.svg')) return Effect.succeed(result)
  return Effect.map(
    rasterizeSvg(cacheDir, hash, result.path),
    Option.match({
      // Handing back the .svg would leave the render backend silently drawing
      // nothing, with no way for the user to learn why.
      onNone: (): FetchAssetResult => err('error', SVG_HELP),
      onSome: (path): FetchAssetResult => ({ ok: true as const, path }),
    }),
  )
}

// ---------------------------------------------------------------------------
// in-flight dedupe
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// chatora/fetchAsset
// ---------------------------------------------------------------------------

// Every format imageSizeOf understands puts its dimensions in the first few hundred
// bytes; reading a prefix keeps a multi-megabyte GIF off the heap.
const HEADER_BYTES = 1024

/**
 * Attach the intrinsic size of the file the client is about to draw. Measured on the
 * *final* path, so a bordered or rasterized variant reports the size it actually has.
 * A failure to measure is not a failure to fetch: the result passes through unchanged.
 */
const withSize = (result: FetchAssetResult): Effect.Effect<FetchAssetResult> => {
  if (!result.ok) return Effect.succeed(result)
  return Effect.tryPromise(async () => {
    const handle = await open(result.path, 'r')
    try {
      const buffer = new Uint8Array(HEADER_BYTES)
      const { bytesRead } = await handle.read(buffer, 0, HEADER_BYTES, 0)
      return imageSizeOf(buffer.subarray(0, bytesRead))
    } finally {
      await handle.close()
    }
  }).pipe(
    Effect.map((size) => (size ? { ...result, ...size } : result)),
    Effect.orElseSucceed(() => result),
  )
}

export const fetchAsset = (params: {
  readonly project: string
  readonly url: string
  readonly border?: BorderParams
}): Effect.Effect<FetchAssetResult, never, SessionState | HttpClient | AssetCache> =>
  Effect.gen(function* () {
    // This is the only place chatora turns page content into a network call, and page content
    // is untrusted: nothing but an absolute http(s) URL gets to be one.
    if (!isFetchableUrl(params.url)) return err('error', 'unsupported asset URL')

    const session = yield* SessionState
    const cache = yield* AssetCache
    const http = yield* HttpClient
    const cacheDir = resolveCacheDir()
    const hash = cacheKey(params.url)
    const border = params.border === undefined ? null : sanitizeBorder(params.border)

    // The bordered/rasterized variants are derived from the plain cached original, so the
    // plain lookup short-circuits the network either way.
    const cached = yield* findCached(cacheDir, hash)
    if (Option.isSome(cached)) {
      const drawable = yield* applyGifFrame(
        cacheDir,
        hash,
        yield* applySvgRaster(cacheDir, hash, { ok: true, path: cached.value }),
      )
      return yield* withSize(yield* applyBorder(cacheDir, hash, drawable, border))
    }

    // Nothing on disk, and nothing cached for a failure either — see FAILURE_BACKOFF_MS.
    const remembered = yield* cache.recallFailure(params.url)
    if (Option.isSome(remembered)) return remembered.value

    const credential = yield* session.getCredential()
    const headersFor = headersForUrl(session.origin, credential)

    // `params.project` isn't read here: Lua already resolved the icon path into an absolute
    // `url` before sending this request. It stays part of the wire contract for symmetry with
    // the other chatora/* requests.
    // Cached under the URL the page holds, fetched from the one Gyazo actually serves —
    // which only its proxy can name (see resolveGyazo).
    const source = Option.match(yield* resolveGyazo(http.fetch, session.origin, params.url), {
      onNone: () => params.url,
      onSome: (media) => media.still,
    })
    const fetched = yield* cache.dedupe(
      params.url,
      fetchAndCache(http.fetch, headersFor, cacheDir, hash, source, (status, wait) =>
        cache.noteFailure(params.url, status, wait),
      ),
    )
    if (fetched.ok) yield* cache.noteSuccess(params.url)
    const drawable = yield* applyGifFrame(
      cacheDir,
      hash,
      yield* applySvgRaster(cacheDir, hash, fetched),
    )
    return yield* withSize(yield* applyBorder(cacheDir, hash, drawable, border))
  })
