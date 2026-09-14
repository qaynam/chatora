// Cosense's "Export for AI" (Smart Context): the page, and the pages within one or two
// links of it, as a single text file for an AI to read. The web offers the same text behind
// a temporary shared URL as well, but that endpoint answers to a browser session only — a
// token gets HTTP 401 back — so only the download half of the feature is here.
import { mkdir, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import type { HttpClient } from '@chatora/core'
import { Effect, Option } from 'effect'
import { log } from './log'
import { type ErrCode, type ErrEnvelope, handle, noCredential } from './pages'
import { SessionState } from './state'

const err = (code: ErrCode, message: string): ErrEnvelope => ({ ok: false, code, message })

/**
 * `$XDG_CACHE_HOME/chatora/export`, falling back to `~/.cache/chatora/export`: the file can
 * be fetched again at any time, so it belongs with the cache rather than among the user's
 * own files. `CHATORA_EXPORT_DIR` replaces the whole path, which is what keeps the tests
 * off a real home directory.
 */
export const resolveExportDir = (): string => {
  const override = process.env.CHATORA_EXPORT_DIR
  if (override !== undefined && override !== '') return override
  const xdgCacheHome = process.env.XDG_CACHE_HOME
  const base =
    xdgCacheHome !== undefined && xdgCacheHome !== '' ? xdgCacheHome : join(homedir(), '.cache')
  return join(base, 'chatora', 'export')
}

// Long enough to still name the page, short enough to stay well under a file name limit.
const MAX_NAME_LENGTH = 80

// Everything a path — or a Windows share — would read as structure, so that any page title
// can name a file.
// biome-ignore lint/suspicious/noControlCharactersInRegex: a control character in a file name is exactly what this drops.
const UNSAFE_IN_NAME = /[\\/:*?"<>|\u0000-\u001f]/g

/** The file one export is written to. */
export const fileNameFor = (title: string, hop: 1 | 2): string => {
  const safe = title.replace(UNSAFE_IN_NAME, '_').trim().slice(0, MAX_NAME_LENGTH)
  return `${safe === '' ? 'page' : safe}-${hop}hop.txt`
}

export interface ExportForAiSuccess {
  readonly ok: true
  readonly path: string
  readonly bytes: number
}

/**
 * Fetches the export and writes it under `resolveExportDir()`, answering with the path and
 * not the text: a two-hop export runs to a megabyte, and the client only opens the file.
 */
export const exportForAi = (params: {
  readonly project: string
  readonly title: string
  readonly hop: 1 | 2
  readonly search?: string
}): Effect.Effect<ExportForAiSuccess | ErrEnvelope, never, SessionState | HttpClient> =>
  handle(
    Effect.gen(function* () {
      const session = yield* SessionState
      const apiOpt = yield* session.getApi()
      if (Option.isNone(apiOpt)) return noCredential()
      const text = yield* apiOpt.value.exportForAi(
        params.project,
        params.title,
        params.hop,
        params.search,
      )
      const dir = join(resolveExportDir(), params.project)
      const path = join(dir, fileNameFor(params.title, params.hop))
      const failure = yield* Effect.tryPromise(async () => {
        await mkdir(dir, { recursive: true })
        await writeFile(path, text, 'utf8')
      }).pipe(
        Effect.as(Option.none<string>()),
        Effect.catchAll((cause) => Effect.succeed(Option.some(String(cause)))),
      )
      if (Option.isSome(failure)) {
        yield* log('warn', 'export could not be written', { path, cause: failure.value })
        return err('error', `書き出せませんでした: ${path}`)
      }
      const bytes = Buffer.byteLength(text, 'utf8')
      yield* log('info', 'exported for ai', { project: params.project, hop: params.hop, bytes })
      return { ok: true as const, path, bytes }
    }),
  )
