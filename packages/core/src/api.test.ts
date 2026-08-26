import { describe, expect, test } from 'bun:test'
import { Effect, Layer, Option } from 'effect'
import { makeCosenseApi } from './api'
import type { Credential } from './credentials'
import { CosenseApiError } from './errors'
import { HttpClient } from './httpClient'

const PAT: Credential = { type: 'pat', value: 'super-secret-pat', source: 'env' }
const SERVICE_ACCOUNT: Credential = {
  type: 'serviceAccount',
  value: 'cs_super-secret',
  source: 'keychain',
}

interface Call {
  url: string
  init: RequestInit
}

const testHttpClient = (
  handler: (url: string, init: RequestInit) => Response | Promise<Response>,
): { layer: Layer.Layer<HttpClient>; calls: Call[] } => {
  const calls: Call[] = []
  const layer = Layer.succeed(
    HttpClient,
    HttpClient.of({
      fetch: (input, init) => {
        calls.push({ url: input, init })
        return Effect.promise(() => Promise.resolve(handler(input, init)))
      },
    }),
  )
  return { layer, calls }
}

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

const run = <A>(
  effect: Effect.Effect<A, CosenseApiError, HttpClient>,
  layer: Layer.Layer<HttpClient>,
) => Effect.runPromise(Effect.provide(effect, layer))

describe('CosenseApi headers', () => {
  test('sends x-personal-access-token for a pat credential', async () => {
    const { layer, calls } = testHttpClient(() =>
      json({ id: 'u1', name: 'qaynam', displayName: 'qaynam', pageFilters: [] }),
    )
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    await run(api.me(), layer)
    const headers = calls[0]?.init.headers as Record<string, string>
    expect(headers['x-personal-access-token']).toBe('super-secret-pat')
    expect(headers['x-service-account-access-key']).toBeUndefined()
  })

  test('sends x-service-account-access-key for a serviceAccount credential', async () => {
    const { layer, calls } = testHttpClient(() =>
      json({ id: 'u1', name: 'bot', displayName: 'bot', pageFilters: [] }),
    )
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: SERVICE_ACCOUNT })
    await run(api.me(), layer)
    const headers = calls[0]?.init.headers as Record<string, string>
    expect(headers['x-service-account-access-key']).toBe('cs_super-secret')
    expect(headers['x-personal-access-token']).toBeUndefined()
  })
})

describe('CosenseApi happy paths', () => {
  test('me()', async () => {
    const { layer } = testHttpClient(() =>
      json({ id: 'u1', name: 'qaynam', displayName: 'Qaynam', pageFilters: [] }),
    )
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    expect(await run(api.me(), layer)).toEqual({
      id: 'u1',
      name: 'qaynam',
      displayName: 'Qaynam',
      pageFilters: [],
    })
  })

  test('projects()', async () => {
    const { layer } = testHttpClient(() => json({ projects: [{ id: 'p1', name: 'myproject' }] }))
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const result = await run(api.projects(), layer)
    expect(result).toHaveLength(1)
    expect(result[0]?.name).toBe('myproject')
  })

  test('listPages() builds the query string and unwraps count/pages', async () => {
    const { layer, calls } = testHttpClient(() =>
      json({ count: 2, pages: [{ id: 'a' }, { id: 'b' }] }),
    )
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const result = await run(
      api.listPages('myproject', { sort: 'updated', limit: 10, skip: 5 }),
      layer,
    )
    expect(result.count).toBe(2)
    expect(result.pages).toHaveLength(2)
    expect(calls[0]?.url).toBe(
      'https://scrapbox.io/api/pages/myproject/?sort=updated&limit=10&skip=5',
    )
  })

  test('getPage() returns Option.some(PageDetail) on a persistent page', async () => {
    const { layer, calls } = testHttpClient(() =>
      json({
        id: 'page1',
        title: 'My Page',
        commitId: 'commit1',
        persistent: true,
        lines: [{ id: 'line1', text: 'hello' }],
        updated: 1700000000,
        views: 12,
      }),
    )
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const page = await run(api.getPage('myproject', 'My Page'), layer)
    // Absent metadata decodes to 0 rather than undefined, so the client never has to
    // distinguish "the API omitted it" from "it is zero".
    expect(page).toEqual(
      Option.some({
        id: 'page1',
        title: 'My Page',
        commitId: 'commit1',
        lines: [{ id: 'line1', text: 'hello', updated: 0, userId: '' }],
        created: 0,
        updated: 1700000000,
        accessed: 0,
        views: 12,
        linked: 0,
        linesCount: 0,
        charsCount: 0,
        pin: 0,
        pageRank: 0,
        snapshotCount: 0,
      }),
    )
    expect(calls[0]?.url).toBe(
      'https://scrapbox.io/api/pages/v2/myproject/My_Page/?followRename=true',
    )
  })

  test('getPage() encodes titles like cosense-cli encodeTitleForUrl (space -> _, unicode kept raw)', async () => {
    const { layer, calls } = testHttpClient(() => json({ persistent: false }))
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    await run(api.getPage('myproject', '日本語 タイトル/foo'), layer)
    expect(calls[0]?.url).toBe(
      'https://scrapbox.io/api/pages/v2/myproject/日本語_タイトル%2Ffoo/?followRename=true',
    )
  })

  test('getPage() returns Option.none on HTTP 404', async () => {
    const { layer } = testHttpClient(() => new Response('not found', { status: 404 }))
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    expect(await run(api.getPage('myproject', 'Missing'), layer)).toEqual(Option.none())
  })

  test('getPage() returns Option.none when the server responds persistent: false', async () => {
    const { layer } = testHttpClient(() =>
      json({
        title: 'New Page',
        persistent: false,
        id: 'fake',
        lines: [{ id: 'fake-line', text: 'New Page' }],
      }),
    )
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    expect(await run(api.getPage('myproject', 'New Page'), layer)).toEqual(Option.none())
  })

  test('relatedPages() issues two requests and merges links1hop/links2hop', async () => {
    const { layer, calls } = testHttpClient((url) => {
      if (url.endsWith('/links1hop')) return json({ links1hop: [{ id: 'a', title: 'A' }] })
      return json({ links2hop: [{ id: 'b', title: 'B' }] })
    })
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const result = await run(api.relatedPages('myproject', 'My Page'), layer)
    expect(result.links1hop).toHaveLength(1)
    expect(result.links2hop).toHaveLength(1)
    expect(calls.map((c) => c.url).sort()).toEqual(
      [
        'https://scrapbox.io/api/pages/v2/myproject/My_Page/links1hop',
        'https://scrapbox.io/api/pages/v2/myproject/My_Page/links2hop',
      ].sort(),
    )
  })

  test('searchFullText()', async () => {
    const { layer, calls } = testHttpClient(() =>
      json({ count: 1, existsExactTitleMatch: true, pages: [{ id: 'a', title: 'A' }] }),
    )
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const result = await run(api.searchFullText('myproject', 'hello world'), layer)
    expect(result.count).toBe(1)
    // field=lines is what makes this a full-text search rather than a title search.
    expect(calls[0]?.url).toBe(
      'https://scrapbox.io/api/pages/myproject/search/query?q=hello+world&skip=0&limit=100&sort=pageRank&field=lines',
    )
  })

  test('searchTitles() accepts a bare array response', async () => {
    const { layer } = testHttpClient(() =>
      json([{ id: 'a', title: 'A', titleLc: 'a', updated: 1, image: null }]),
    )
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const result = await run(api.searchTitles('myproject'), layer)
    expect(result).toHaveLength(1)
    expect(result[0]?.title).toBe('A')
  })

  test('previewEdit() and submitEdit() POST JSON with Content-Type', async () => {
    const { layer, calls } = testHttpClient((url) => {
      if (url.endsWith('/preview'))
        return json({ previewId: 'pv1', expireAt: 'later', pagePreview: null })
      return json({ commitId: 'c1', page: { title: 'My Page' } })
    })
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const preview = await run(
      api.previewEdit('myproject', { changes: [{ _delete: 'line1' }] }),
      layer,
    )
    expect(preview.previewId).toBe('pv1')
    const submit = await run(api.submitEdit('myproject', 'pv1'), layer)
    expect(submit.commitId).toBe('c1')
    for (const call of calls) {
      expect(call.init.method).toBe('POST')
      expect((call.init.headers as Record<string, string>)['Content-Type']).toBe('application/json')
    }
    expect(calls[1]?.init.body).toBe(JSON.stringify({ previewId: 'pv1' }))
  })
})

describe('CosenseApi error handling', () => {
  test('searchVector() returns an empty page list on HTTP 490', async () => {
    const { layer } = testHttpClient(() => new Response('feature disabled', { status: 490 }))
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    expect(await run(api.searchVector('myproject', 'q'), layer)).toEqual({ pages: [] })
  })

  const runFailure = <A>(
    effect: Effect.Effect<A, CosenseApiError, HttpClient>,
    layer: Layer.Layer<HttpClient>,
  ) => Effect.runPromise(Effect.flip(Effect.provide(effect, layer)))

  test('previewEdit() surfaces HTTP 409 NotFastForward as a typed CosenseApiError', async () => {
    const { layer } = testHttpClient(
      () =>
        new Response(JSON.stringify({ error: 'NotFastForward', latest: null }), { status: 409 }),
    )
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const failure = await runFailure(api.previewEdit('myproject', { changes: [] }), layer)
    expect(failure).toMatchObject({ status: 409, code: 'NotFastForward' })
  })

  test('submitEdit() surfaces HTTP 409 DuplicateTitle', async () => {
    const { layer } = testHttpClient(
      () => new Response(JSON.stringify({ error: 'DuplicateTitle' }), { status: 409 }),
    )
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const failure = await runFailure(api.submitEdit('myproject', 'pv1'), layer)
    expect(failure).toMatchObject({ status: 409, code: 'DuplicateTitle' })
  })

  test('a manual redirect (3xx) is treated as an error, not followed', async () => {
    const { layer } = testHttpClient(
      () =>
        new Response(null, { status: 302, headers: { location: 'https://evil.example/steal' } }),
    )
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const failure = await runFailure(api.me(), layer)
    expect(failure).toBeInstanceOf(CosenseApiError)
  })

  test('CosenseApi requests redirect: manual so credential headers never follow a redirect', async () => {
    const { layer, calls } = testHttpClient(() =>
      json({ id: 'u1', name: 'a', displayName: 'a', pageFilters: [] }),
    )
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    await run(api.me(), layer)
    expect(calls[0]?.init.redirect).toBe('manual')
  })

  test('error messages never contain the credential value', async () => {
    const { layer } = testHttpClient(() => new Response('unauthorized', { status: 401 }))
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const failure = await runFailure(api.me(), layer)
    expect(failure).toBeInstanceOf(CosenseApiError)
    expect(failure.message).not.toContain(PAT.value)
    expect(String(failure)).not.toContain(PAT.value)
  })
})

describe('markAccessed', () => {
  const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })

  test('POSTs to the accessed endpoint', async () => {
    const { layer, calls } = testHttpClient(() => json({}))
    await run(api.markAccessed('proj', 'page1'), layer)
    expect(calls).toHaveLength(1)
    expect(calls[0]?.url).toBe('https://scrapbox.io/api/pages/proj/page1/accessed')
    expect(calls[0]?.init.method).toBe('POST')
  })

  test('falls back to GET when POST is rejected', async () => {
    const { layer, calls } = testHttpClient((_url, init) =>
      init.method === 'POST' ? json({}, 405) : json({}),
    )
    await run(api.markAccessed('proj', 'page1'), layer)
    expect(calls.map((c) => c.init.method)).toEqual(['POST', 'GET'])
  })

  test('never fails, whatever the endpoint does', async () => {
    const { layer } = testHttpClient(() => json({}, 404))
    expect(await run(api.markAccessed('proj', 'page1'), layer)).toBeUndefined()
  })
})

describe('renamed pages and redirects', () => {
  // Cosense keeps a renamed page reachable under its old title and redirects to the
  // current one, which is what a link written before the rename still points at.
  test('a same-origin redirect is followed, carrying the credential', async () => {
    const seen: string[] = []
    const { layer, calls } = testHttpClient((url) => {
      seen.push(url)
      if (seen.length === 1) {
        return new Response(null, {
          status: 302,
          headers: { location: '/api/pages/v2/myproject/New_Title' },
        })
      }
      return json({ id: 'pg1', title: 'New Title', persistent: true, lines: [] })
    })
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const page = await Effect.runPromise(
      api.getPage('myproject', 'Old Title').pipe(Effect.provide(layer)),
    )
    expect(Option.isSome(page)).toBe(true)
    expect(seen).toHaveLength(2)
    expect(seen[1]).toBe('https://scrapbox.io/api/pages/v2/myproject/New_Title')
    expect(calls[1]?.init.headers).toMatchObject({ 'x-personal-access-token': PAT.value })
  })

  test('a redirect off the origin is refused rather than replayed there', async () => {
    const { layer } = testHttpClient(
      () =>
        new Response(null, { status: 302, headers: { location: 'https://evil.example/steal' } }),
    )
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const result = await Effect.runPromise(
      Effect.either(api.getPage('myproject', 'Page').pipe(Effect.provide(layer))),
    )
    expect(result._tag).toBe('Left')
  })

  test('a redirect loop gives up instead of spinning', async () => {
    let hops = 0
    const { layer } = testHttpClient(() => {
      hops++
      return new Response(null, {
        status: 302,
        headers: { location: '/api/pages/v2/myproject/Round' },
      })
    })
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const result = await Effect.runPromise(
      Effect.either(api.getPage('myproject', 'Round').pipe(Effect.provide(layer))),
    )
    expect(result._tag).toBe('Left')
    expect(hops).toBeLessThanOrEqual(5)
  })
})

describe('searchTitles walks the whole project', () => {
  const titlePage = (count: number, followingId: string | null) =>
    new Response(
      JSON.stringify(Array.from({ length: count }, (_, i) => ({ id: String(i), title: `t${i}` }))),
      {
        status: 200,
        headers: {
          'content-type': 'application/json',
          ...(followingId === null ? {} : { 'x-following-id': followingId }),
        },
      },
    )

  // The endpoint caps a response at 10000 entries and names where the next page starts.
  // Stopping at the first would report everything past it as a page that does not exist.
  test('follows x-following-id until the project runs out', async () => {
    let call = 0
    const { layer, calls } = testHttpClient(() => {
      call++
      return call === 1 ? titlePage(10000, 'second') : titlePage(7, null)
    })
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const titles = await Effect.runPromise(api.searchTitles('big').pipe(Effect.provide(layer)))
    expect(titles).toHaveLength(10007)
    expect(calls[1]?.url).toContain('followingId=second')
  })

  test('a project that fits in one page is one request', async () => {
    const { layer, calls } = testHttpClient(() => titlePage(12, null))
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const titles = await Effect.runPromise(api.searchTitles('small').pipe(Effect.provide(layer)))
    expect(titles).toHaveLength(12)
    expect(calls).toHaveLength(1)
  })

  // A short page means the end even when the header still names one, and the loop is
  // bounded anyway so a server that always names a next page cannot spin forever.
  test('a server that always names a next page still terminates', async () => {
    const { layer, calls } = testHttpClient(() => titlePage(10000, 'again'))
    const api = makeCosenseApi({ origin: 'https://scrapbox.io', credential: PAT })
    const titles = await Effect.runPromise(api.searchTitles('endless').pipe(Effect.provide(layer)))
    expect(calls.length).toBeLessThanOrEqual(20)
    expect(titles.length).toBe(calls.length * 10000)
  })
})
