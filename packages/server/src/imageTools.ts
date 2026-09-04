// What ImageMagick (and, for SVG, librsvg) does to a stored picture before a terminal sees
// it. Every step caches its output in the store under its own prefix and falls back to its
// input when the tool is missing or fails: none of this is worth losing the picture over.
import { execFile } from 'node:child_process'
import { open } from 'node:fs/promises'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { Effect, Option } from 'effect'
import { cacheKey, findCached } from './assetStore'
import { type ImageSize, imageSizeOf } from './imageSize'

export interface BorderParams {
  readonly width: number
  readonly color: string
  readonly padding: number
}

export const execFileAsync = promisify(execFile)

// Everything reaching an ImageMagick argv goes through these. A rejected value came from
// user config, so the whole border is skipped rather than guessed at.
const clampPx = (value: unknown, fallback: number): number => {
  const n = typeof value === 'number' && Number.isFinite(value) ? Math.floor(value) : fallback
  return Math.min(64, Math.max(0, n))
}
const COLOR_RE = /^(#[0-9a-fA-F]{3,8}|[a-zA-Z]+)$/

export const sanitizeBorder = (border: BorderParams): BorderParams | null => {
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
export const resolveMagick = firstAvailable([{ cmd: 'magick' }, { cmd: 'convert' }], '-version')

// -compose copy on the second -border: without it, IM floods the border color through the
// transparent padding ring instead of only framing it.
export const borderArgs = (border: BorderParams): string[] => [
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
]

/**
 * Composites a frame into the image itself — a transparent padding ring, then the border
 * line — since a terminal can only frame an image by baking it into the pixels. The cache
 * name is *prefixed* with the params hash so the plain `findCached(hash)` prefix lookup can
 * never pick up a bordered variant. Falls back to the original path when ImageMagick is
 * missing or the composite fails: the border is cosmetic, the image is not.
 */
export const withBorder = (
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

    const args = [sourcePath, ...borderArgs(border), borderedPath]
    return yield* Effect.tryPromise(() => execFileAsync(magick.cmd, args)).pipe(
      Effect.as(borderedPath),
      Effect.orElseSucceed(() => sourcePath),
    )
  })

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
export const rasterizeSvg = (
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
export const flattenGif = (
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

// Every format imageSizeOf understands puts its dimensions in the first few hundred
// bytes; reading a prefix keeps a multi-megabyte GIF off the heap.
const HEADER_BYTES = 1024

/** The intrinsic pixel size of the file at `path`, or undefined when it cannot be read. */
export const measure = (path: string): Effect.Effect<ImageSize | undefined> =>
  Effect.tryPromise(async () => {
    const handle = await open(path, 'r')
    try {
      const buffer = new Uint8Array(HEADER_BYTES)
      const { bytesRead } = await handle.read(buffer, 0, HEADER_BYTES, 0)
      return imageSizeOf(buffer.subarray(0, bytesRead))
    } finally {
      await handle.close()
    }
  }).pipe(Effect.orElseSucceed((): ImageSize | undefined => undefined))

/**
 * Longest edge a picture is handed over with. A terminal keeps every image it shows
 * decoded and evicts old ones past a budget (Ghostty: 320 MB); a phone photo decodes to
 * 50 MB and a tall screenshot to 130 MB, so a page of them pushes its own pictures off the
 * screen. Nothing is drawn taller than a few dozen rows, which this covers at retina
 * density.
 */
const MAX_IMAGE_EDGE = 2048

/**
 * `path`, or a copy no larger than MAX_IMAGE_EDGE on either side, cached under an
 * `s`-prefixed name (same reasoning as the `b`, `r` and `g` prefixes). A picture that
 * cannot be measured or shrunk passes through as it is.
 */
export const shrink = (cacheDir: string, hash: string, path: string): Effect.Effect<string> =>
  Effect.gen(function* () {
    const size = yield* measure(path)
    if (size === undefined || (size.width <= MAX_IMAGE_EDGE && size.height <= MAX_IMAGE_EDGE))
      return path
    const shrunkName = `s${hash}`
    const shrunkPath = join(cacheDir, `${shrunkName}.png`)
    const existing = yield* findCached(cacheDir, shrunkName)
    if (Option.isSome(existing)) return existing.value

    const magick = yield* Effect.promise(resolveMagick)
    if (magick === null) return path
    const fit = `${MAX_IMAGE_EDGE}x${MAX_IMAGE_EDGE}>`
    return yield* Effect.tryPromise(() =>
      execFileAsync(magick.cmd, [`${path}[0]`, '-auto-orient', '-resize', fit, shrunkPath]),
    ).pipe(
      Effect.as(shrunkPath),
      Effect.orElseSucceed(() => path),
    )
  })
