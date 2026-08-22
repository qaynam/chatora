import { describe, expect, test } from 'bun:test'
import { CosenseApi, CosenseApiError } from './api'
import type { Credential } from './credentials'

const PAT: Credential = { type: 'pat', value: 'super-secret-pat', source: 'env' }
const SERVICE_ACCOUNT: Credential = {
  type: 'serviceAccount',
  value: 'cs_super-secret',
  source: 'settingsJson',
}

interface Call {
  url: string
  init: RequestInit
}

const makeFetch = (
  handler: (url: string, init: RequestInit) => Response | Promise<Response>,
): { fetch: typeof fetch; calls: Call[] } => {
  const calls: Call[] = []
  const fetchImpl = (async (input: Parameters<typeof fetch>[0], init?: RequestInit) => {
    const url = String(input)
    const usedInit = init ?? {}
    calls.push({ url, init: usedInit })
    return handler(url, usedInit)
  }) as typeof fetch
  return { fetch: fetchImpl, calls }
}

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

describe('CosenseApi headers', () => {
  test('sends x-personal-access-token for a pat credential', async () => {
    const { fetch: fetchImpl, calls } = makeFetch(() =>
      json({ id: 'u1', name: 'qaynam', displayName: 'qaynam' }),
    )
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    await api.me()
    const headers = calls[0]?.init.headers as Record<string, string>
    expect(headers['x-personal-access-token']).toBe('super-secret-pat')
    expect(headers['x-service-account-access-key']).toBeUndefined()
  })

  test('sends x-service-account-access-key for a serviceAccount credential', async () => {
    const { fetch: fetchImpl, calls } = makeFetch(() =>
      json({ id: 'u1', name: 'bot', displayName: 'bot' }),
    )
    const api = new CosenseApi({
      origin: 'https://scrapbox.io',
      credential: SERVICE_ACCOUNT,
      fetch: fetchImpl,
    })
    await api.me()
    const headers = calls[0]?.init.headers as Record<string, string>
    expect(headers['x-service-account-access-key']).toBe('cs_super-secret')
    expect(headers['x-personal-access-token']).toBeUndefined()
  })
})

describe('CosenseApi happy paths', () => {
  test('me()', async () => {
    const { fetch: fetchImpl } = makeFetch(() =>
      json({ id: 'u1', name: 'qaynam', displayName: 'Qaynam' }),
    )
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    expect(await api.me()).toEqual({ id: 'u1', name: 'qaynam', displayName: 'Qaynam' })
  })

  test('projects()', async () => {
    const { fetch: fetchImpl } = makeFetch(() =>
      json({ projects: [{ id: 'p1', name: 'myproject' }] }),
    )
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    const result = await api.projects()
    expect(result).toHaveLength(1)
    expect(result[0]?.name).toBe('myproject')
  })

  test('listPages() builds the query string and unwraps count/pages', async () => {
    const { fetch: fetchImpl, calls } = makeFetch(() =>
      json({ count: 2, pages: [{ id: 'a' }, { id: 'b' }] }),
    )
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    const result = await api.listPages('myproject', { sort: 'updated', limit: 10, skip: 5 })
    expect(result.count).toBe(2)
    expect(result.pages).toHaveLength(2)
    expect(calls[0]?.url).toBe(
      'https://scrapbox.io/api/pages/myproject/?sort=updated&limit=10&skip=5',
    )
  })

  test('getPage() returns a PageDetail on a persistent page', async () => {
    const { fetch: fetchImpl, calls } = makeFetch(() =>
      json({
        id: 'page1',
        title: 'My Page',
        commitId: 'commit1',
        persistent: true,
        lines: [{ id: 'line1', text: 'hello' }],
      }),
    )
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    const page = await api.getPage('myproject', 'My Page')
    expect(page).toEqual({
      id: 'page1',
      title: 'My Page',
      commitId: 'commit1',
      lines: [{ id: 'line1', text: 'hello' }],
    })
    expect(calls[0]?.url).toBe('https://scrapbox.io/api/pages/v2/myproject/My_Page')
  })

  test('getPage() encodes titles like cosense-cli encodeTitleForUrl (space -> _, unicode kept raw)', async () => {
    const { fetch: fetchImpl, calls } = makeFetch(() => json({ persistent: false }))
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    await api.getPage('myproject', '日本語 タイトル/foo')
    expect(calls[0]?.url).toBe('https://scrapbox.io/api/pages/v2/myproject/日本語_タイトル%2Ffoo')
  })

  test('getPage() returns null on HTTP 404', async () => {
    const { fetch: fetchImpl } = makeFetch(() => new Response('not found', { status: 404 }))
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    expect(await api.getPage('myproject', 'Missing')).toBeNull()
  })

  test('getPage() returns null when the server responds persistent: false', async () => {
    const { fetch: fetchImpl } = makeFetch(() =>
      json({
        title: 'New Page',
        persistent: false,
        id: 'fake',
        lines: [{ id: 'fake-line', text: 'New Page' }],
      }),
    )
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    expect(await api.getPage('myproject', 'New Page')).toBeNull()
  })

  test('relatedPages() issues two requests and merges links1hop/links2hop', async () => {
    const { fetch: fetchImpl, calls } = makeFetch((url) => {
      if (url.endsWith('/links1hop')) return json({ links1hop: [{ id: 'a', title: 'A' }] })
      return json({ links2hop: [{ id: 'b', title: 'B' }] })
    })
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    const result = await api.relatedPages('myproject', 'My Page')
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
    const { fetch: fetchImpl, calls } = makeFetch(() =>
      json({ count: 1, existsExactTitleMatch: true, pages: [{ id: 'a', title: 'A' }] }),
    )
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    const result = await api.searchFullText('myproject', 'hello world')
    expect(result.count).toBe(1)
    expect(calls[0]?.url).toBe(
      'https://scrapbox.io/api/pages/myproject/search/query?q=hello%20world',
    )
  })

  test('searchTitles() accepts a bare array response', async () => {
    const { fetch: fetchImpl } = makeFetch(() =>
      json([{ id: 'a', title: 'A', titleLc: 'a', updated: 1, image: null }]),
    )
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    const result = await api.searchTitles('myproject')
    expect(result).toHaveLength(1)
    expect(result[0]?.title).toBe('A')
  })

  test('previewEdit() and submitEdit() POST JSON with Content-Type', async () => {
    const { fetch: fetchImpl, calls } = makeFetch((url) => {
      if (url.endsWith('/preview'))
        return json({ previewId: 'pv1', expireAt: 'later', pagePreview: null })
      return json({ commitId: 'c1', page: { title: 'My Page' } })
    })
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    const preview = await api.previewEdit('myproject', { changes: [{ _delete: 'line1' }] })
    expect(preview.previewId).toBe('pv1')
    const submit = await api.submitEdit('myproject', 'pv1')
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
    const { fetch: fetchImpl } = makeFetch(() => new Response('feature disabled', { status: 490 }))
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    expect(await api.searchVector('myproject', 'q')).toEqual({ pages: [] })
  })

  test('previewEdit() surfaces HTTP 409 NotFastForward as a typed CosenseApiError', async () => {
    const { fetch: fetchImpl } = makeFetch(
      () =>
        new Response(JSON.stringify({ error: 'NotFastForward', latest: null }), { status: 409 }),
    )
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    await expect(api.previewEdit('myproject', { changes: [] })).rejects.toMatchObject({
      status: 409,
      code: 'NotFastForward',
    })
  })

  test('submitEdit() surfaces HTTP 409 DuplicateTitle', async () => {
    const { fetch: fetchImpl } = makeFetch(
      () => new Response(JSON.stringify({ error: 'DuplicateTitle' }), { status: 409 }),
    )
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    await expect(api.submitEdit('myproject', 'pv1')).rejects.toMatchObject({
      status: 409,
      code: 'DuplicateTitle',
    })
  })

  test('a manual redirect (3xx) is treated as an error, not followed', async () => {
    const { fetch: fetchImpl } = makeFetch(
      () =>
        new Response(null, { status: 302, headers: { location: 'https://evil.example/steal' } }),
    )
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    await expect(api.me()).rejects.toBeInstanceOf(CosenseApiError)
  })

  test('CosenseApi requests redirect: manual so credential headers never follow a redirect', async () => {
    const { fetch: fetchImpl, calls } = makeFetch(() =>
      json({ id: 'u1', name: 'a', displayName: 'a' }),
    )
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    await api.me()
    expect(calls[0]?.init.redirect).toBe('manual')
  })

  test('error messages never contain the credential value', async () => {
    const { fetch: fetchImpl } = makeFetch(() => new Response('unauthorized', { status: 401 }))
    const api = new CosenseApi({ origin: 'https://scrapbox.io', credential: PAT, fetch: fetchImpl })
    try {
      await api.me()
      throw new Error('expected api.me() to throw')
    } catch (err) {
      expect(err).toBeInstanceOf(CosenseApiError)
      expect((err as Error).message).not.toContain(PAT.value)
      expect(String(err)).not.toContain(PAT.value)
    }
  })
})
