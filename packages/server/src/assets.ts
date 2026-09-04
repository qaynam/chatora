// The two asset requests a page makes: `chatora/fetchAsset` for one picture and
// `chatora/composeAssets` for a row of them. Fetching is the one place page content turns
// into a network call; what happens to the bytes afterwards lives in assetStore.ts (disk),
// imageTools.ts (ImageMagick) and assetCache.ts (what the session remembers).

import { join } from 'node:path'
import type { Credential, HttpClientShape } from '@chatora/core'
import { HttpClient } from '@chatora/core'
import { Data, Effect, Option } from 'effect'
import { AssetCache } from './assetCache'
import { cacheKey, extensionFor, findCached, resolveCacheDir, writeAtomic } from './assetStore'
import { resolveGyazo } from './gyazo'
import {
  type BorderParams,
  borderArgs,
  execFileAsync,
  flattenGif,
  measure,
  rasterizeSvg,
  resolveMagick,
  sanitizeBorder,
  shrink,
  withBorder,
} from './imageTools'
import { log } from './log'
import type { ErrCode, ErrEnvelope } from './pages'
import { SessionState } from './state'

export { AssetCache, AssetCacheLive } from './assetCache'
export type { BorderParams } from './imageTools'

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
    const path = yield* writeAtomic(cacheDir, hash, ext, new Uint8Array(body)).pipe(
      Effect.mapError((error) => new AssetFetchError({ status: 0, message: error.message })),
    )
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
// the drawable variant of what is on disk
// ---------------------------------------------------------------------------

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

const applyShrink = (
  cacheDir: string,
  hash: string,
  result: FetchAssetResult,
): Effect.Effect<FetchAssetResult> => {
  if (!result.ok) return Effect.succeed(result)
  return Effect.map(shrink(cacheDir, hash, result.path), (path) => ({ ok: true as const, path }))
}

/**
 * Attach the intrinsic size of the file the client is about to draw. Measured on the
 * *final* path, so a bordered or rasterized variant reports the size it actually has.
 * A failure to measure is not a failure to fetch: the result passes through unchanged.
 */
const withSize = (result: FetchAssetResult): Effect.Effect<FetchAssetResult> => {
  if (!result.ok) return Effect.succeed(result)
  return Effect.map(measure(result.path), (size) => (size ? { ...result, ...size } : result))
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
      const drawable = yield* applyShrink(
        cacheDir,
        hash,
        yield* applyGifFrame(
          cacheDir,
          hash,
          yield* applySvgRaster(cacheDir, hash, { ok: true, path: cached.value }),
        ),
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
    const drawable = yield* applyShrink(
      cacheDir,
      hash,
      yield* applyGifFrame(cacheDir, hash, yield* applySvgRaster(cacheDir, hash, fetched)),
    )
    return yield* withSize(yield* applyBorder(cacheDir, hash, drawable, border))
  })

// ---------------------------------------------------------------------------
// chatora/composeAssets
// ---------------------------------------------------------------------------

export interface GalleryTile {
  readonly width: number
  readonly height: number
}

export interface ComposeAssetsSuccess {
  readonly ok: true
  readonly path: string
  /**
   * Indices into `urls` of the pictures in the strip, left to right. One that could not be
   * fetched, or that lies past `MAX_STRIP_MEMBERS`, is left out.
   */
  readonly members: readonly number[]
  readonly width?: number
  readonly height?: number
}
export type ComposeAssetsResult = ComposeAssetsSuccess | ErrEnvelope

/** Transparent columns between two tiles that carry no border of their own. */
const GALLERY_GAP_PX = 8
// The client already wraps by window width; this only keeps a line that pastes dozens of
// pictures from becoming one strip too wide for a terminal to hold in memory.
const MAX_STRIP_MEMBERS = 16

// User config again, so it is clamped before it reaches an argv.
const clampTile = (value: unknown, fallback: number): number => {
  const n = typeof value === 'number' && Number.isFinite(value) ? Math.floor(value) : fallback
  return Math.min(2048, Math.max(16, n))
}

const MAGICK_HELP = '画像を並べるには ImageMagick が要ります。`brew install imagemagick` で入ります'

/**
 * One picture made of several: each of `urls` scaled to fill `tile` and cropped to it, then
 * laid side by side. A line of pictures is drawn as a single placement this way, because a
 * render backend has nowhere to put a second picture beside a first that is taller than a
 * text row. Same-size tiles cropped to fit is also how the web client draws such a line.
 *
 * The strip is cached under the paths of the members it holds, so a member that turns up
 * later (a fetch that failed and then succeeded) makes a different strip, not a stale one.
 */
export const composeAssets = (params: {
  readonly project: string
  readonly urls: readonly string[]
  readonly tile: GalleryTile
  readonly border?: BorderParams
}): Effect.Effect<ComposeAssetsResult, never, SessionState | HttpClient | AssetCache> =>
  Effect.gen(function* () {
    const tile = {
      width: clampTile(params.tile?.width, 540),
      height: clampTile(params.tile?.height, 720),
    }
    const border = params.border === undefined ? null : sanitizeBorder(params.border)
    const fetched = yield* Effect.forEach(
      params.urls.slice(0, MAX_STRIP_MEMBERS),
      (url) => fetchAsset({ project: params.project, url }),
      { concurrency: 4 },
    )
    const members = fetched.flatMap((result, index) =>
      result.ok ? [{ index, path: result.path }] : [],
    )
    if (members.length === 0) return err('error', '並べる画像を 1 枚も取得できませんでした')

    const cacheDir = resolveCacheDir()
    const borderKey = border === null ? '' : `${border.width}\0${border.color}\0${border.padding}`
    const stripName = `c${cacheKey(
      [...members.map((m) => m.path), `${tile.width}x${tile.height}`, borderKey].join('\0'),
    )}`
    const stripPath = join(cacheDir, `${stripName}.png`)
    const resultFor = (path: string): Effect.Effect<ComposeAssetsResult> =>
      Effect.map(withSize({ ok: true, path }), (sized) =>
        sized.ok ? { ...sized, members: members.map((m) => m.index) } : sized,
      )

    const existing = yield* findCached(cacheDir, stripName)
    if (Option.isSome(existing)) return yield* resultFor(existing.value)

    const magick = yield* Effect.promise(resolveMagick)
    if (magick === null) return err('error', MAGICK_HELP)

    const size = `${tile.width}x${tile.height}`
    const tileArgs = (path: string, last: boolean): string[] => [
      '(',
      path,
      '-auto-orient',
      '-resize',
      `${size}^`,
      '-gravity',
      'center',
      '-extent',
      size,
      ...(border === null ? [] : borderArgs(border)),
      // A bordered tile already carries its padding ring; a bare one gets a gap on the right.
      ...(last || border !== null
        ? []
        : ['-background', 'none', '-gravity', 'east', '-splice', `${GALLERY_GAP_PX}x0`]),
      ')',
    ]
    const args = [
      ...members.flatMap((m, i) => tileArgs(m.path, i === members.length - 1)),
      '-background',
      'none',
      '+append',
      `PNG32:${stripPath}`,
    ]
    return yield* Effect.tryPromise(() => execFileAsync(magick.cmd, args)).pipe(
      Effect.flatMap(() => resultFor(stripPath)),
      Effect.catchAll((error) =>
        log('warn', 'asset compose failed', { detail: String(error) }).pipe(
          Effect.as(err('error', '画像を並べられませんでした')),
        ),
      ),
    )
  })
