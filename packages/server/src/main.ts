import type { HttpClient } from '@chatora/core'
import {
  type AccountStore,
  AccountStoreLive,
  CommandExecutorLive,
  CredentialStoreLive,
  HttpClientLive,
} from '@chatora/core'
import { Layer, ManagedRuntime } from 'effect'
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
import { definitionLocation, findDefinitionTarget } from './definition'
import { computeImageTargets } from './images'
import * as handlers from './pages'
import { makeSessionStateLayer, type SessionState } from './state'
import { computeTokens, encodeTokens, type RawToken, TOKEN_TYPES } from './tokens'
import { parseUri } from './uriScheme'

const DEFAULT_ORIGIN = 'https://scrapbox.io'

const connection = createConnection()
const documents = new TextDocuments(TextDocument)

type AppRuntime = ManagedRuntime.ManagedRuntime<
  SessionState | HttpClient | AssetCache | AccountStore,
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
): Layer.Layer<SessionState | HttpClient | AssetCache | AccountStore> => {
  const accountStore = AccountStoreLive.pipe(Layer.provide(CommandExecutorLive))
  const credentialStore = CredentialStoreLive.pipe(
    Layer.provide(Layer.mergeAll(CommandExecutorLive, accountStore)),
  )
  return Layer.mergeAll(
    HttpClientLive,
    AssetCacheLive,
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

connection.onInitialize((params: InitializeParams): InitializeResult => {
  const options = params.initializationOptions as { origin?: unknown } | undefined
  const origin =
    typeof options?.origin === 'string' && options.origin !== '' ? options.origin : DEFAULT_ORIGIN
  runtime = ManagedRuntime.make(buildAppLayer(origin))

  return {
    capabilities: {
      textDocumentSync: TextDocumentSyncKind.Incremental,
      semanticTokensProvider: {
        legend: { tokenTypes: [...TOKEN_TYPES], tokenModifiers: [] },
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

connection.onDefinition((params: DefinitionParams) => {
  const doc = documents.get(params.textDocument.uri)
  if (!doc) return null
  const parsed = parseUri(params.textDocument.uri)
  if (!parsed) return null

  const lineText = normalizeCrLf(doc.getText()).split('\n')[params.position.line] ?? ''
  const target = findDefinitionTarget(lineText, params.position.character, parsed.project)
  return target ? definitionLocation(target) : null
})

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
connection.onRequest('chatora/savePage', (params: { uri: string }) =>
  runtime.runPromise(handlers.savePage(params.uri, documents.get(params.uri)?.getText())),
)
connection.onRequest('chatora/relatedPages', (params: { project: string; title: string }) =>
  runtime.runPromise(handlers.relatedPages(params)),
)
type DecorationsResult =
  | { ok: true; conceal: ReturnType<typeof computeConcealRanges> }
  | { ok: false; code: string; message: string }
connection.onRequest(
  'chatora/decorations',
  async (params: { uri: string }): Promise<DecorationsResult> => {
    const doc = documents.get(params.uri)
    if (!doc) return { ok: false, code: 'error', message: 'document not synced' }
    return { ok: true, conceal: computeConcealRanges(doc.getText()) }
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

documents.listen(connection)
connection.listen()
