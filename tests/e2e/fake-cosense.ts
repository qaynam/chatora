// A fake Cosense (Scrapbox) REST API server for the chatora e2e harness.
//
// This is deliberately NOT a faithful re-implementation of Cosense — it exists only to
// serve the handful of endpoints @chatora/core's CosenseApi (packages/core/src/api.ts)
// actually calls, with shapes matching docs/ARCHITECTURE.md and packages/core/src/types.ts,
// so the real Neovim plugin -> @chatora/server (node, LSP/stdio) -> HTTP chain can be
// exercised end-to-end without any real credentials or network access.
//
// Every request is logged (method, path, query, body, response status) in-memory and
// exposed via `GET /__test/requests` (no auth) for the orchestrator (run.ts) to assert
// against after the Neovim scenario finishes. `POST /__test/reset` restores fixtures.
//
// Auth: every `/api/*` route requires header `x-personal-access-token: test-pat`;
// otherwise it 401s with `{"error":"NotLoggedIn"}` (mirrors the real API's error shape —
// see packages/core/src/api.ts parseErrorCode/CosenseApiError).

const TOKEN = 'test-pat'
const PROJECT = 'testproj'

// ---------------------------------------------------------------------------------------
// Fixture state
// ---------------------------------------------------------------------------------------

interface FixtureLine {
  id: string
  text: string
}

interface FixturePage {
  id: string
  title: string
  commitId: string
  lines: FixtureLine[]
}

const makeFixturePages = (): Map<string, FixturePage> => {
  const pages = new Map<string, FixturePage>()
  pages.set('ホーム', {
    id: 'pg1',
    title: 'ホーム',
    commitId: 'c1',
    lines: [
      { id: 'l1', text: 'ホーム' },
      { id: 'l2', text: 'これは[メモ]へのリンク' },
      { id: 'l3', text: '#tag もある' },
      // A marker run mixing the harness's custom `|` notation with the official `*`.
      { id: 'l4', text: '[|* 特徴]' },
      { id: 'l5', text: '> 引用された行' },
      { id: 'l6', text: '[メモ#6a44c8050000000000650784]' },
    ],
  })
  pages.set('メモ', {
    id: 'pg2',
    title: 'メモ',
    commitId: 'c1',
    lines: [
      { id: 'm1', text: 'メモ' },
      { id: 'm2', text: '検索ヒット行' },
      // A line id in the shape a real one has, so a `[メモ#<id>]` link resolves to this row.
      { id: '6a44c8050000000000650784', text: 'リンクの飛び先' },
    ],
  })
  return pages
}

// RawChange shapes, mirroring packages/core/src/types.ts (kept local — tests/e2e doesn't
// depend on @chatora/core so the harness stays fully self-contained).
interface RawInsertChange {
  _insert: string
  lines: { id: string; text: string }
}
interface RawUpdateChange {
  _update: string
  lines: { text: string }
}
interface RawDeleteChange {
  _delete: string
}
type RawChange = RawInsertChange | RawUpdateChange | RawDeleteChange

const isInsert = (c: RawChange): c is RawInsertChange => '_insert' in c
const isUpdate = (c: RawChange): c is RawUpdateChange => '_update' in c
const isDelete = (c: RawChange): c is RawDeleteChange => '_delete' in c

/** Applies page-edit-for-ai RawChanges to a fixture page's lines, in place. */
const applyChanges = (page: FixturePage, changes: readonly RawChange[]): void => {
  for (const change of changes) {
    if (isInsert(change)) {
      const newLine: FixtureLine = { id: change.lines.id, text: change.lines.text }
      if (change._insert === '_end') {
        page.lines.push(newLine)
        continue
      }
      const idx = page.lines.findIndex((l) => l.id === change._insert)
      if (idx === -1) page.lines.push(newLine)
      else page.lines.splice(idx, 0, newLine)
    } else if (isUpdate(change)) {
      const line = page.lines.find((l) => l.id === change._update)
      if (line) line.text = change.lines.text
    } else if (isDelete(change)) {
      const idx = page.lines.findIndex((l) => l.id === change._delete)
      if (idx !== -1) page.lines.splice(idx, 1)
    }
  }
}

// ---------------------------------------------------------------------------------------
// Request log
// ---------------------------------------------------------------------------------------

export interface RequestLogEntry {
  method: string
  path: string
  query: string
  body: unknown
  status: number
}

// ---------------------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------------------

export interface FakeCosenseHandle {
  readonly port: number
  readonly origin: string
  stop(): void
}

export const startFakeCosense = (): FakeCosenseHandle => {
  let pages = makeFixturePages()
  let requests: RequestLogEntry[] = []
  // The last successful preview's recorded change set, keyed by the previewId we handed
  // out (always 'pv1' — this fake only ever needs one live preview at a time).
  let pendingPreview: { pageId?: string; changes: RawChange[] } | null = null

  const jsonResponse = (body: unknown, status: number): Response =>
    new Response(JSON.stringify(body), {
      status,
      headers: { 'content-type': 'application/json' },
    })

  const server = Bun.serve({
    port: 0,
    hostname: '127.0.0.1',
    async fetch(req) {
      const url = new URL(req.url)
      const path = url.pathname
      const method = req.method

      let body: unknown
      if (method === 'POST') {
        const text = await req.text()
        if (text.length > 0) {
          try {
            body = JSON.parse(text)
          } catch {
            body = text
          }
        }
      }

      const respond = (payload: unknown, status = 200): Response => {
        requests.push({ method, path, query: url.search, body, status })
        return jsonResponse(payload, status)
      }

      // --- test-only control endpoints: no auth, not part of the fake Cosense API ---
      if (path === '/__test/requests' && method === 'GET') {
        return jsonResponse(requests, 200)
      }
      if (path === '/__test/reset' && method === 'POST') {
        pages = makeFixturePages()
        requests = []
        pendingPreview = null
        return jsonResponse({ ok: true }, 200)
      }
      // Stands in for another person editing the page while nvim has it open — the one
      // thing the scenario cannot cause from inside the editor. Expressed as operations
      // rather than a line list so the fixture's own line ids survive: the ids are what
      // the merge matches on, and a caller that replaced them would be testing nothing.
      if (path === '/__test/remote-edit' && method === 'POST') {
        const edit = body as {
          title: string
          update?: { index: number; text: string }[]
          append?: string[]
        }
        const page = pages.get(edit.title)
        if (!page) return jsonResponse({ ok: false, error: 'no such page' }, 404)
        for (const { index, text } of edit.update ?? []) {
          const line = page.lines[index]
          if (line) line.text = text
        }
        for (const text of edit.append ?? []) {
          page.lines.push({ id: `remote${page.lines.length}`, text })
        }
        page.commitId = `${page.commitId}+remote`
        return jsonResponse({ ok: true, lines: page.lines }, 200)
      }

      if (!path.startsWith('/api/')) {
        return respond({ error: 'NotFound', path }, 404)
      }

      // --- auth gate: every real API route requires the PAT header ---
      const token = req.headers.get('x-personal-access-token')
      if (token !== TOKEN) {
        return respond({ error: 'NotLoggedIn' }, 401)
      }

      // GET /api/users/me
      if (path === '/api/users/me' && method === 'GET') {
        return respond({ id: 'user1', name: 'tester', displayName: 'Tester' }, 200)
      }

      // GET /api/projects
      if (path === '/api/projects' && method === 'GET') {
        return respond(
          { projects: [{ id: 'p1', name: PROJECT, displayName: 'Test Project' }] },
          200,
        )
      }

      // GET /api/pages/testproj/  (note trailing slash; sort/limit/skip in query)
      if (path === `/api/pages/${PROJECT}/` && method === 'GET') {
        return respond(
          {
            count: 2,
            pages: [
              { id: 'pg1', title: 'ホーム', updated: 1700000000, pin: 0 },
              { id: 'pg2', title: 'メモ', updated: 1690000000, pin: 0 },
            ],
          },
          200,
        )
      }

      // GET /api/pages/testproj/search/query?q=...
      if (path === `/api/pages/${PROJECT}/search/query` && method === 'GET') {
        return respond(
          {
            count: 1,
            pages: [{ title: 'メモ', lines: ['メモ', '検索ヒット行'], words: ['ヒット'] }],
          },
          200,
        )
      }

      // GET /api/pages/testproj/search/titles
      if (path === `/api/pages/${PROJECT}/search/titles` && method === 'GET') {
        return respond([{ title: 'ホーム' }, { title: 'メモ' }], 200)
      }

      // POST /api/pages/v2/testproj/page-edit-for-ai/preview
      if (path === `/api/pages/v2/${PROJECT}/page-edit-for-ai/preview` && method === 'POST') {
        const reqBody = body as { pageId?: string; changes?: RawChange[] } | undefined
        const changes = reqBody?.changes ?? []
        pendingPreview = { changes }
        if (reqBody?.pageId !== undefined) pendingPreview.pageId = reqBody.pageId
        return respond({ previewId: 'pv1', expireAt: '2999-01-01T00:00:00Z' }, 200)
      }

      // POST /api/pages/v2/testproj/page-edit-for-ai/submit
      if (path === `/api/pages/v2/${PROJECT}/page-edit-for-ai/submit` && method === 'POST') {
        const reqBody = body as { previewId?: string } | undefined
        if (reqBody?.previewId !== 'pv1' || !pendingPreview) {
          return respond({ error: 'InvalidPreview' }, 422)
        }
        // Mutate the in-memory ホーム page so a post-submit refetch sees consistent data —
        // this fake only ever edits ホーム in the e2e scenario, so hardcoding is fine.
        const page = pages.get('ホーム')
        if (page) {
          applyChanges(page, pendingPreview.changes)
          page.commitId = 'c2'
        }
        pendingPreview = null
        return respond({ commitId: 'c2', page: { title: 'ホーム' } }, 200)
      }

      // POST /api/pages/:project/:pageId/accessed -> 204, the real read-tracking
      // endpoint (verified against a scrapbox.io capture).
      if (method === 'POST' && /^\/api\/pages\/[^/]+\/[^/]+\/accessed$/.test(path)) {
        requests.push({ method, path, query: url.search, body, status: 204 })
        return new Response(null, { status: 204 })
      }

      // GET /api/pages/v2/testproj/:title[/links1hop|/links2hop]
      const v2Prefix = `/api/pages/v2/${PROJECT}/`
      if (path.startsWith(v2Prefix) && method === 'GET') {
        let rest = path.slice(v2Prefix.length)
        // getPage asks for `<title>/?followRename=true`, so the segment arrives with a
        // trailing slash the real API tolerates.
        if (rest.endsWith('/')) rest = rest.slice(0, -1)
        let hop: 'links1hop' | 'links2hop' | null = null
        if (rest.endsWith('/links1hop')) {
          hop = 'links1hop'
          rest = rest.slice(0, -'/links1hop'.length)
        } else if (rest.endsWith('/links2hop')) {
          hop = 'links2hop'
          rest = rest.slice(0, -'/links2hop'.length)
        }

        // The client (CosenseApi.getPage/relatedPages, packages/core/src/api.ts) builds this
        // path segment with encodeTitleForUrl(title) — raw unicode, space -> '_', % / ? #
        // escaped — then hands the whole URL to fetch(). The WHATWG URL parser then UTF-8
        // percent-encodes the raw unicode bytes on the wire, so what we receive here is a
        // plain percent-encoded path segment; decodeURIComponent inverts it back to the
        // original title for our (space/%/?/# -free) fixture titles.
        let title: string
        try {
          title = decodeURIComponent(rest)
        } catch {
          title = rest
        }

        if (hop === 'links1hop') {
          const links1hop = title === 'ホーム' ? [{ id: 'pg2', title: 'メモ', linked: 3 }] : []
          return respond({ links1hop }, 200)
        }
        if (hop === 'links2hop') {
          return respond({ links2hop: [] }, 200)
        }

        const page = pages.get(title)
        if (page) {
          return respond(
            {
              id: page.id,
              title: page.title,
              commitId: page.commitId,
              persistent: true,
              lines: page.lines,
              updated: 1700000000,
              views: 42,
              linked: 6,
            },
            200,
          )
        }
        // Real Cosense: a title with no page yet still 200s, with persistent:false and a
        // fake/unsafe id (see docs/ARCHITECTURE.md "存在しないページは404にならない").
        return respond(
          {
            persistent: false,
            id: 'fake',
            commitId: 'fake',
            lines: [{ id: 'fakeline', text: title }],
          },
          200,
        )
      }

      return respond({ error: 'NotFound', path }, 404)
    },
  })

  return {
    port: server.port,
    origin: `http://127.0.0.1:${server.port}`,
    stop: () => server.stop(true),
  }
}

// Allow running this file directly for manual poking: `bun tests/e2e/fake-cosense.ts`.
if (import.meta.main) {
  const handle = startFakeCosense()
  console.log(`fake-cosense listening on ${handle.origin} (Ctrl-C to stop)`)
}
