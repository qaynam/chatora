import type { HttpClient } from '@chatora/core'
import {
  type AccountStore,
  AccountStoreLive,
  CommandExecutorLive,
  CredentialStoreLive,
} from '@chatora/core'
import { Effect, Layer, ManagedRuntime } from 'effect'
import {
  type CompletionParams,
  createConnection,
  type DefinitionParams,
  type InitializeParams,
  type InitializeResult,
  type SemanticTokens,
  type SemanticTokensParams,
  type SemanticTokensRangeParams,
  TextDocumentSyncKind,
  TextDocuments,
} from 'vscode-languageserver/node'
import { TextDocument } from 'vscode-languageserver-textdocument'
import { type AssetCache, AssetCacheLive, type BorderParams, fetchAsset } from './assets'
import { buildCompletionItems, detectCompletionInDocument } from './completion'
import { computeConcealRanges } from './decorations'
import { definitionLocation, findDefinitionTarget, findUrlTarget } from './definition'
import { HttpClientLogged } from './httpLog'
import { computeImageTargets } from './images'
import { activeLogPath, log } from './log'
import { type NotationSpec, notationSpecs, setNotations } from './notations'
import * as handlers from './pages'
import { computeQuoteRanges } from './quote'
import { type ReadState, ReadStateLive } from './readState'
import { makeSessionStateLayer, type SessionState } from './state'
import { computeTokens, encodeTokens, type RawToken, TOKEN_TYPES } from './tokens'
import { uploadImage } from './upload'
import { parseUri } from './uriScheme'

const DEFAULT_ORIGIN = 'https://scrapbox.io'

const connection = createConnection()
const documents = new TextDocuments(TextDocument)

type AppRuntime = ManagedRuntime.ManagedRuntime<
  SessionState | HttpClient | AssetCache | AccountStore | ReadState,
  never
>

/**
 * One origin's worth of infrastructure: HttpClient (network), AssetCache
 * (chatora/fetchAsset's in-flight fetch dedupe), AccountStore (the multi-account index +
 * Keychain, shared as a top-level service so the chatora/*Account* handlers can use it
 * directly), and SessionState wired to CredentialStore, which itself now reads through
 * AccountStore before falling back to the legacy per-origin Keychain entry.
 */
const buildAppLayer = (
  origin: string,
): Layer.Layer<SessionState | HttpClient | AssetCache | AccountStore | ReadState> => {
  const accountStore = AccountStoreLive.pipe(Layer.provide(CommandExecutorLive))
  const credentialStore = CredentialStoreLive.pipe(
    Layer.provide(Layer.mergeAll(CommandExecutorLive, accountStore)),
  )
  return Layer.mergeAll(
    HttpClientLogged,
    AssetCacheLive,
    ReadStateLive,
    accountStore,
    makeSessionStateLayer(origin).pipe(Layer.provide(credentialStore)),
  )
}

// Replaced in onInitialize once the real origin (from initializationOptions) is known; every
// chatora/* and completion handler below reads this `let` at call time, so a re-initialize
// (uncommon, but the LSP spec doesn't forbid it) picks up the new runtime automatically.
let runtime: AppRuntime = ManagedRuntime.make(buildAppLayer(DEFAULT_ORIGIN))

const normalizeCrLf = (text: string): string => text.replace(/\r\n?/g, '\n')

const inRange = (token: RawToken, range: { start: Position; end: Position }): boolean => {
  const afterStart =
    token.line > range.start.line ||
    (token.line === range.start.line && token.char + token.length > range.start.character)
  const beforeEnd =
    token.line < range.end.line ||
    (token.line === range.end.line && token.char < range.end.character)
  return afterStart && beforeEnd
}

interface Position {
  line: number
  character: number
}

const toSemanticTokens = (tokens: RawToken[]): SemanticTokens => ({ data: encodeTokens(tokens) })

type UrlAtResult = { ok: true; url: string | null } | { ok: false; code: string; message: string }

// Marker characters an official notation already owns: the four decoration flags
// ([* /-_]), formulas ([$ ]) and bracket-nested links ([[ ]]).
const RESERVED_MARKERS = new Set(['*', '/', '-', '_', '$', '['])
const NOTATION_NAME_RE = /^[A-Za-z0-9_]+$/

// initializationOptions come from the client, which is not trusted: drop anything malformed
// instead of failing initialize.
const validateNotations = (input: unknown): NotationSpec[] => {
  if (!Array.isArray(input)) return []
  const seen = new Set<string>()
  const out: NotationSpec[] = []
  for (const entry of input) {
    if (typeof entry !== 'object' || entry === null) continue
    const { marker, name } = entry as { marker?: unknown; name?: unknown }
    if (typeof marker !== 'string' || [...marker].length !== 1 || RESERVED_MARKERS.has(marker))
      continue
    if (typeof name !== 'string' || !NOTATION_NAME_RE.test(name)) continue
    if (seen.has(marker)) continue
    seen.add(marker)
    out.push({ marker, name })
  }
  return out
}

connection.onInitialize((params: InitializeParams): InitializeResult => {
  const options = params.initializationOptions as
    | { origin?: unknown; notations?: unknown; log?: unknown }
    | undefined
  // log.ts reads the environment per call, so this is all it takes to turn the
  // diagnostic log on for the rest of the process.
  if (typeof options?.log === 'string' && options.log !== '') process.env.CHATORA_LOG = options.log
  const origin =
    typeof options?.origin === 'string' && options.origin !== '' ? options.origin : DEFAULT_ORIGIN
  runtime = ManagedRuntime.make(buildAppLayer(origin))
  setNotations(validateNotations(options?.notations))
  void Effect.runPromise(log('info', 'chatora server initialized', { origin }))

  return {
    capabilities: {
      textDocumentSync: TextDocumentSyncKind.Incremental,
      semanticTokensProvider: {
        legend: {
          tokenTypes: [...TOKEN_TYPES, ...notationSpecs().map((s) => s.name)],
          tokenModifiers: [],
        },
        full: true,
        range: true,
      },
      // ' ' keeps multi-word link queries alive: clients dismiss the menu on
      // space (end of keyword), and the trigger reopens it; outside an
      // unclosed [ / # context the server returns null so it is a no-op.
      completionProvider: { triggerCharacters: ['[', '#', ' '] },
      definitionProvider: true,
    },
  }
})

connection.languages.semanticTokens.on((params: SemanticTokensParams): SemanticTokens => {
  const doc = documents.get(params.textDocument.uri)
  if (!doc) return { data: [] }
  return toSemanticTokens(computeTokens(doc.getText()))
})

connection.languages.semanticTokens.onRange((params: SemanticTokensRangeParams): SemanticTokens => {
  const doc = documents.get(params.textDocument.uri)
  if (!doc) return { data: [] }
  const tokens = computeTokens(doc.getText()).filter((t) => inRange(t, params.range))
  return toSemanticTokens(tokens)
})

connection.onCompletion(async (params: CompletionParams) => {
  const doc = documents.get(params.textDocument.uri)
  if (!doc) return null
  const parsed = parseUri(params.textDocument.uri)
  if (!parsed) return null

  const detection = detectCompletionInDocument(doc.getText(), params.position)
  if (!detection) return null

  const items = await runtime.runPromise(
    buildCompletionItems(parsed.project, params.position.line, detection),
  )
  // isIncomplete keeps clients re-querying on every keystroke so the server-side
  // filtering (capped at 50 items) stays authoritative instead of client-side
  // narrowing of a stale first batch.
  return { isIncomplete: true, items }
})

connection.onDefinition(async (params: DefinitionParams) => {
  const doc = documents.get(params.textDocument.uri)
  if (!doc) return null
  const parsed = parseUri(params.textDocument.uri)
  if (!parsed) return null

  const lineText = normalizeCrLf(doc.getText()).split('\n')[params.position.line] ?? ''
  const target = findDefinitionTarget(lineText, params.position.character, parsed.project)
  if (!target) return null
  // `[title#lineId]` names a line, and where that line sits is only knowable from the page.
  const row =
    target.lineId === undefined
      ? 0
      : await runtime.runPromise(handlers.lineRow(target.project, target.title, target.lineId))
  return definitionLocation(target, row)
})

// Async like every other envelope-returning handler: onRequest only infers the
// {ok:true}|{ok:false} union as one response type through a Promise.
connection.onRequest(
  'chatora/urlAt',
  async (params: { uri: string; line: number; character: number }): Promise<UrlAtResult> => {
    const doc = documents.get(params.uri)
    if (!doc) return { ok: false, code: 'error', message: 'document not synced' }
    const lineText = normalizeCrLf(doc.getText()).split('\n')[params.line] ?? ''
    return { ok: true, url: findUrlTarget(lineText, params.character) }
  },
)

connection.onRequest('chatora/authStatus', () => runtime.runPromise(handlers.authStatus()))
connection.onRequest('chatora/login', (params: { pat: string }) =>
  runtime.runPromise(handlers.login(params.pat)),
)
connection.onRequest('chatora/logout', () => runtime.runPromise(handlers.logout()))
connection.onRequest('chatora/accounts', () => runtime.runPromise(handlers.accounts()))
connection.onRequest('chatora/addAccount', (params: { pat: string }) =>
  runtime.runPromise(handlers.addAccount(params.pat)),
)
connection.onRequest('chatora/useAccount', (params: { id: string }) =>
  runtime.runPromise(handlers.useAccount(params)),
)
connection.onRequest('chatora/removeAccount', (params: { id: string }) =>
  runtime.runPromise(handlers.removeAccount(params)),
)
connection.onRequest('chatora/projects', () => runtime.runPromise(handlers.projects()))
connection.onRequest('chatora/allProjects', () => runtime.runPromise(handlers.allProjects()))
connection.onRequest('chatora/useProject', (params: { project: string }) =>
  runtime.runPromise(handlers.useProject(params)),
)
connection.onRequest(
  'chatora/listPages',
  (params: {
    project: string
    skip?: number
    limit?: number
    filterType?: string
    filterValue?: string
    unreadOnly?: boolean
  }) => runtime.runPromise(handlers.listPages(params)),
)
connection.onRequest('chatora/openPage', (params: { project: string; title: string }) =>
  runtime.runPromise(handlers.openPage(params)),
)
connection.onRequest('chatora/newPage', (params: { project: string; title: string }) =>
  runtime.runPromise(handlers.newPage(params)),
)
connection.onRequest('chatora/previewPage', (params: { project: string; title: string }) =>
  runtime.runPromise(handlers.previewPage(params)),
)
connection.onRequest('chatora/logPath', async () => ({
  ok: true as const,
  path: activeLogPath() ?? null,
}))
connection.onRequest('chatora/savePage', (params: { uri: string }) =>
  runtime.runPromise(handlers.savePage(params.uri, documents.get(params.uri)?.getText())),
)
connection.onRequest('chatora/syncPage', (params: { uri: string }) =>
  runtime.runPromise(handlers.syncPage(params.uri, documents.get(params.uri)?.getText())),
)
connection.onRequest('chatora/telomere', (params: { uri: string; lines: string[] }) =>
  runtime.runPromise(handlers.telomere(params)),
)
connection.onRequest('chatora/deletePage', (params: { uri: string }) =>
  runtime.runPromise(handlers.deletePage(params.uri)),
)
connection.onRequest('chatora/emptyLinks', (params: { uri: string }) =>
  runtime.runPromise(handlers.emptyLinks(params.uri, documents.get(params.uri)?.getText())),
)
connection.onRequest('chatora/relatedPages', (params: { project: string; title: string }) =>
  runtime.runPromise(handlers.relatedPages(params)),
)
type DecorationsResult =
  | {
      ok: true
      conceal: ReturnType<typeof computeConcealRanges>
      quotes: ReturnType<typeof computeQuoteRanges>
    }
  | { ok: false; code: string; message: string }
connection.onRequest(
  'chatora/decorations',
  async (params: { uri: string }): Promise<DecorationsResult> => {
    const doc = documents.get(params.uri)
    if (!doc) return { ok: false, code: 'error', message: 'document not synced' }
    const text = doc.getText()
    return { ok: true, conceal: computeConcealRanges(text), quotes: computeQuoteRanges(text) }
  },
)
type ImagesResult =
  | { ok: true; images: ReturnType<typeof computeImageTargets> }
  | { ok: false; code: string; message: string }
connection.onRequest('chatora/images', async (params: { uri: string }): Promise<ImagesResult> => {
  const doc = documents.get(params.uri)
  if (!doc) return { ok: false, code: 'error', message: 'document not synced' }
  return { ok: true, images: computeImageTargets(doc.getText()) }
})
connection.onRequest(
  'chatora/search',
  (params: { project: string; query: string; mode?: 'fulltext' | 'vector' }) =>
    runtime.runPromise(handlers.search(params)),
)
connection.onRequest(
  'chatora/fetchAsset',
  (params: { project: string; url: string; border?: BorderParams }) =>
    runtime.runPromise(fetchAsset(params)),
)
connection.onRequest(
  'chatora/uploadImage',
  (params: { project: string; title: string; path: string }) =>
    runtime.runPromise(uploadImage(params)),
)

documents.listen(connection)
connection.listen()
