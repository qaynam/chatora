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
import { buildCompletionItems, detectCompletionInDocument } from './completion'
import { definitionLocation, findDefinitionTarget } from './definition'
import * as handlers from './pages'
import { ServerState } from './state'
import { computeTokens, encodeTokens, type RawToken, TOKEN_TYPES } from './tokens'
import { parseUri } from './uriScheme'

const DEFAULT_ORIGIN = 'https://scrapbox.io'

const connection = createConnection()
const documents = new TextDocuments(TextDocument)

let state: ServerState = new ServerState(DEFAULT_ORIGIN)

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
  state = new ServerState(origin)

  return {
    capabilities: {
      textDocumentSync: TextDocumentSyncKind.Incremental,
      semanticTokensProvider: {
        legend: { tokenTypes: [...TOKEN_TYPES], tokenModifiers: [] },
        full: true,
        range: true,
      },
      completionProvider: { triggerCharacters: ['[', '#'] },
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

  const items = await buildCompletionItems(state, parsed.project, params.position.line, detection)
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

connection.onRequest('chatora/authStatus', () => handlers.authStatus(state))
connection.onRequest('chatora/login', (params: { pat: string }) => handlers.login(state, params))
connection.onRequest('chatora/logout', () => handlers.logout(state))
connection.onRequest('chatora/projects', () => handlers.projects(state))
connection.onRequest(
  'chatora/listPages',
  (params: { project: string; skip?: number; limit?: number }) => handlers.listPages(state, params),
)
connection.onRequest('chatora/openPage', (params: { project: string; title: string }) =>
  handlers.openPage(state, params),
)
connection.onRequest('chatora/newPage', (params: { project: string; title: string }) =>
  handlers.newPage(state, params),
)
connection.onRequest('chatora/savePage', (params: { uri: string }) =>
  handlers.savePage(state, documents, params),
)
connection.onRequest('chatora/relatedPages', (params: { project: string; title: string }) =>
  handlers.relatedPages(state, params),
)
connection.onRequest(
  'chatora/search',
  (params: { project: string; query: string; mode?: 'fulltext' | 'vector' }) =>
    handlers.search(state, params),
)

documents.listen(connection)
connection.listen()
