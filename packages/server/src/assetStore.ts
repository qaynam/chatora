// The on-disk asset store: `$XDG_CACHE_HOME/chatora/assets`, one file per URL hash plus
// the variants derived from it under a letter prefix (`b` bordered, `r` rasterized, `g` GIF
// frame, `s` shrunk, `c` composed strip). Nothing here knows where the bytes came from.
import { createHash, randomBytes } from 'node:crypto'
import { mkdir, readdir, rename, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { Data, Effect, Option } from 'effect'

/**
 * `$XDG_CACHE_HOME/chatora/assets`, falling back to `~/.cache/chatora/assets`.
 * `CHATORA_CACHE_DIR` overrides the whole path when set, so tests can point the cache at a
 * throwaway temp directory instead of touching the real home directory.
 */
export const resolveCacheDir = (): string => {
  const override = process.env.CHATORA_CACHE_DIR
  if (override !== undefined && override !== '') return override
  const xdgCacheHome = process.env.XDG_CACHE_HOME
  const base =
    xdgCacheHome !== undefined && xdgCacheHome !== '' ? xdgCacheHome : join(homedir(), '.cache')
  return join(base, 'chatora', 'assets')
}

/** First 32 hex chars of sha256(url) — enough to make collisions a non-concern for a local icon/image cache. */
export const cacheKey = (url: string): string =>
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
export const extensionFor = (contentType: string | null): string => {
  if (contentType === null) return FALLBACK_EXTENSION
  const mime = contentType.split(';', 1)[0]?.trim().toLowerCase() ?? ''
  return CONTENT_TYPE_EXTENSIONS[mime] ?? FALLBACK_EXTENSION
}

/**
 * Any file already on disk for this hash, regardless of which extension it was written with —
 * a cache hit skips the network entirely, since icons rarely change (a future refresh command
 * can invalidate by deleting the cache directory).
 */
export const findCached = (cacheDir: string, hash: string): Effect.Effect<Option.Option<string>> =>
  Effect.tryPromise(() => readdir(cacheDir)).pipe(
    Effect.map((names) => names.find((name) => name.startsWith(hash))),
    Effect.map((name) => (name === undefined ? Option.none() : Option.some(join(cacheDir, name)))),
    // readdir fails with ENOENT before the cache directory has ever been created; either way
    // that just means "not cached yet".
    Effect.orElseSucceed(() => Option.none<string>()),
  )

/** Writing to the store failed; `message` names the step and never a path or a header. */
export class StoreError extends Data.TaggedError('StoreError')<{ readonly message: string }> {}

export const writeAtomic = (
  cacheDir: string,
  hash: string,
  ext: string,
  body: Uint8Array,
): Effect.Effect<string, StoreError> =>
  Effect.gen(function* () {
    yield* Effect.tryPromise(() => mkdir(cacheDir, { recursive: true })).pipe(
      Effect.mapError(() => new StoreError({ message: 'failed to create asset cache directory' })),
    )
    const finalPath = join(cacheDir, `${hash}${ext}`)
    // Write-then-rename: a concurrent reader (snacks placing the previous refresh's image)
    // never observes a partially-written file at the final path.
    const tmpPath = join(cacheDir, `.${hash}${ext}.${randomBytes(4).toString('hex')}.tmp`)
    yield* Effect.tryPromise(() => writeFile(tmpPath, body)).pipe(
      Effect.mapError(() => new StoreError({ message: 'failed to write cached asset' })),
    )
    yield* Effect.tryPromise(() => rename(tmpPath, finalPath)).pipe(
      Effect.mapError(() => new StoreError({ message: 'failed to finalize cached asset' })),
    )
    return finalPath
  })
