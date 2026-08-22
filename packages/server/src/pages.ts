import type { Credential } from '@chatora/core'
import {
  CosenseApiError,
  computeChanges,
  createNewLineId,
  deleteCredential,
  storeCredential,
} from '@chatora/core'
import type { TextDocuments } from 'vscode-languageserver/node'
import type { TextDocument } from 'vscode-languageserver-textdocument'
import { textToLines } from './lines'
import type { BasePageState, ServerState } from './state'
import { formatUri } from './uriScheme'

export type ErrCode = 'unauthorized' | 'notFastForward' | 'error'
export interface ErrEnvelope {
  ok: false
  code: ErrCode
  message: string
}

const err = (code: ErrCode, message: string): ErrEnvelope => ({ ok: false, code, message })
const noCredential = (): ErrEnvelope => err('unauthorized', 'not logged in')

/**
 * Every chatora/* handler goes through this: never throws to the client, and never leaks the
 * credential value (CosenseApiError's message is built server-side in @chatora/core from
 * status/statusText only — see api.ts requestJson — so it is always safe to forward as-is).
 */
const guard = async <R>(fn: () => Promise<R>): Promise<R | ErrEnvelope> => {
  try {
    return await fn()
  } catch (error) {
    if (error instanceof CosenseApiError) {
      if (error.status === 401 || error.status === 403) {
        return err('unauthorized', 'authentication failed')
      }
      if (error.code === 'NotFastForward') {
        return err('notFastForward', 'remote page has changed; reload and try again')
      }
      return err('error', error.message)
    }
    return err('error', error instanceof Error ? error.message : String(error))
  }
}

// ---------------------------------------------------------------------------
// auth
// ---------------------------------------------------------------------------

interface AuthStatusResult {
  ok: true
  authenticated: boolean
  origin: string
  source?: Credential['source']
  user?: { id: string; name: string; displayName: string }
}

export const authStatus = (state: ServerState): Promise<AuthStatusResult | ErrEnvelope> =>
  guard(async (): Promise<AuthStatusResult> => {
    const credential = await state.getCredential()
    if (!credential) return { ok: true, authenticated: false, origin: state.origin }
    const user = await state.ensureVerified()
    if (!user) return { ok: true, authenticated: false, origin: state.origin }
    return { ok: true, authenticated: true, origin: state.origin, source: credential.source, user }
  })

export const login = (
  state: ServerState,
  params: { pat: string },
): Promise<AuthStatusResult | ErrEnvelope> =>
  guard(async (): Promise<AuthStatusResult | ErrEnvelope> => {
    const credential: Credential = { type: 'pat', value: params.pat, source: 'keychain' }
    const api = state.apiFor(credential)
    try {
      const user = await api.me()
      await storeCredential(state.origin, params.pat)
      state.invalidateCredentials()
      state.verifiedUser = user
      return { ok: true, authenticated: true, origin: state.origin, source: 'keychain', user }
    } catch {
      return err('unauthorized', 'invalid token')
    }
  })

export const logout = (state: ServerState): Promise<{ ok: true } | ErrEnvelope> =>
  guard(async (): Promise<{ ok: true }> => {
    try {
      await deleteCredential(state.origin)
    } catch {
      // ignore — "not found" and any other delete failure are both fine to ignore on logout
    }
    state.invalidateCredentials()
    return { ok: true }
  })

// ---------------------------------------------------------------------------
// projects / pages
// ---------------------------------------------------------------------------

export const projects = (state: ServerState) =>
  guard(async () => {
    const api = await state.getApi()
    if (!api) return noCredential()
    return { ok: true as const, projects: await api.projects() }
  })

export const listPages = (
  state: ServerState,
  params: { project: string; skip?: number; limit?: number },
) =>
  guard(async () => {
    const api = await state.getApi(params.project)
    if (!api) return noCredential()
    const opts: { skip?: number; limit?: number; sort: string } = { sort: 'updated' }
    if (params.skip !== undefined) opts.skip = params.skip
    if (params.limit !== undefined) opts.limit = params.limit
    const result = await api.listPages(params.project, opts)
    return { ok: true as const, count: result.count, pages: result.pages }
  })

export const openPage = (state: ServerState, params: { project: string; title: string }) =>
  guard(async () => {
    const api = await state.getApi(params.project)
    if (!api) return noCredential()
    const uri = formatUri(params.project, params.title)
    const page = await api.getPage(params.project, params.title)

    if (page) {
      const text = page.lines.map((l) => l.text).join('\n')
      state.setPage(uri, {
        project: params.project,
        title: params.title,
        pageId: page.id,
        commitId: page.commitId,
        baseLines: page.lines,
        exists: true,
      })
      return {
        ok: true as const,
        uri,
        text,
        exists: true,
        pageId: page.id,
        commitId: page.commitId,
      }
    }

    state.setPage(uri, {
      project: params.project,
      title: params.title,
      baseLines: [],
      exists: false,
    })
    return { ok: true as const, uri, text: params.title, exists: false }
  })

// `chatora/newPage` is a plain alias — the Lua side may call either.
export const newPage = openPage

// ---------------------------------------------------------------------------
// savePage
// ---------------------------------------------------------------------------

export const savePage = (
  state: ServerState,
  documents: TextDocuments<TextDocument>,
  params: { uri: string },
) =>
  guard(async () => {
    const doc = documents.get(params.uri)
    if (!doc) return err('error', 'document not synced')

    const base = state.getPage(params.uri)
    if (!base) return err('error', 'page state not found; reopen the page')

    const api = await state.getApi(base.project)
    if (!api) return noCredential()

    const nextLines = textToLines(doc.getText())
    const userId = state.verifiedUser?.id ?? ''
    const changes = computeChanges(base.baseLines, nextLines, () => createNewLineId(userId))

    if (changes.length === 0) {
      return { ok: true as const, commitId: base.commitId ?? '', noop: true }
    }

    const preview = await api.previewEdit(
      base.project,
      base.pageId !== undefined ? { pageId: base.pageId, changes } : { changes },
    )
    const submit = await api.submitEdit(base.project, preview.previewId)

    const finalTitle = submit.page?.title ?? submit.titleChanged?.to ?? base.title
    // refetched should be non-null right after a successful submit; falling back to what we
    // just sent keeps savePage well-defined even if the server races us on this read.
    const refetched = await api.getPage(base.project, finalTitle)
    const submittedText = nextLines.join('\n')
    const responseText =
      refetched && refetched.lines.map((l) => l.text).join('\n') !== submittedText
        ? refetched.lines.map((l) => l.text).join('\n')
        : undefined

    const newBase: BasePageState = refetched
      ? {
          project: base.project,
          title: finalTitle,
          baseLines: refetched.lines,
          exists: true,
          pageId: refetched.id,
          commitId: refetched.commitId,
        }
      : {
          project: base.project,
          title: finalTitle,
          baseLines: base.baseLines,
          exists: true,
          ...(base.pageId !== undefined ? { pageId: base.pageId } : {}),
          commitId: submit.commitId,
        }

    const newUri = formatUri(base.project, finalTitle)
    if (newUri !== params.uri) state.deletePage(params.uri)
    state.setPage(newUri, newBase)

    return {
      ok: true as const,
      commitId: newBase.commitId ?? '',
      ...(responseText !== undefined ? { text: responseText } : {}),
      ...(submit.titleChanged !== undefined ? { titleChanged: submit.titleChanged } : {}),
    }
  })

// ---------------------------------------------------------------------------
// related pages / search
// ---------------------------------------------------------------------------

export const relatedPages = (state: ServerState, params: { project: string; title: string }) =>
  guard(async () => {
    const api = await state.getApi(params.project)
    if (!api) return noCredential()
    const result = await api.relatedPages(params.project, params.title)
    return { ok: true as const, links1hop: result.links1hop, links2hop: result.links2hop }
  })

export const search = (
  state: ServerState,
  params: { project: string; query: string; mode?: 'fulltext' | 'vector' },
) =>
  guard(async () => {
    const api = await state.getApi(params.project)
    if (!api) return noCredential()

    if (params.mode === 'vector') {
      const result = await api.searchVector(params.project, params.query)
      return { ok: true as const, pages: result.pages.map((p) => ({ title: p.title })) }
    }

    const result = await api.searchFullText(params.project, params.query)
    return {
      ok: true as const,
      pages: result.pages.map((p) => ({ title: p.title, lines: p.lines })),
    }
  })
