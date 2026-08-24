import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { Credential } from '@chatora/core'
import { CredentialStore, HttpClient } from '@chatora/core'
import { Effect, Layer, Option } from 'effect'
import { type AssetCache, AssetCacheLive, fetchAsset } from './assets'
import { makeSessionStateLayer, type SessionState } from './state'

const ORIGIN = 'https://scrapbox.io'
const PAT: Credential = { type: 'pat', value: 'secret-pat', source: 'keychain' }

let cacheDir: string

beforeEach(() => {
  cacheDir = mkdtempSync(join(tmpdir(), 'chatora-assets-test-'))
  process.env.CHATORA_CACHE_DIR = cacheDir
})

afterEach(() => {
  delete process.env.CHATORA_CACHE_DIR
  rmSync(cacheDir, { recursive: true, force: true })
})

interface Call {
  readonly url: string
  readonly init: RequestInit
}

const testHttpClient = (
  handler: (url: string, init: RequestInit) => Response,
): { layer: Layer.Layer<HttpClient>; calls: Call[] } => {
  const calls: Call[] = []
  const layer = Layer.succeed(
    HttpClient,
    HttpClient.of({
      fetch: (input, init) => {
        calls.push({ url: input, init })
        return Effect.sync(() => handler(input, init))
      },
    }),
  )
  return { layer, calls }
}

const testCredentialStore = (
  initial: Option.Option<Credential>,
): { layer: Layer.Layer<CredentialStore> } => ({
  layer: Layer.succeed(
    CredentialStore,
    CredentialStore.of({
      resolve: () => Effect.succeed(initial),
      store: () => Effect.void,
      remove: () => Effect.void,
    }),
  ),
})

const png = (byte: number): Response =>
  new Response(new Uint8Array([byte]), { status: 200, headers: { 'content-type': 'image/png' } })

const headerOf = (call: Call | undefined, name: string): string | undefined => {
  const headers = call?.init.headers as Record<string, string> | undefined
  return headers?.[name]
}

const runOnce = <A, E>(
  program: Effect.Effect<A, E, SessionState | HttpClient | AssetCache>,
  httpLayer: Layer.Layer<HttpClient>,
  credentialLayer: Layer.Layer<CredentialStore>,
): Promise<A> =>
  Effect.runPromise(
    program.pipe(
      Effect.provide(httpLayer),
      Effect.provide(AssetCacheLive),
      Effect.provide(makeSessionStateLayer(ORIGIN).pipe(Layer.provide(credentialLayer))),
    ),
  )

describe('fetchAsset', () => {
  test('fetches, caches to disk, and returns the local path', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() => png(1))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const result = await runOnce(
      fetchAsset({ project: 'p', url: 'https://i.gyazo.com/one.png' }),
      httpLayer,
      credLayer,
    )
    expect(result.ok).toBe(true)
    if (result.ok) expect(result.path.startsWith(cacheDir)).toBe(true)
    expect(calls).toHaveLength(1)
  })

  test('a second request for the same URL is a cache hit and never refetches', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() => png(2))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const url = 'https://i.gyazo.com/cached.png'

    const first = await runOnce(fetchAsset({ project: 'p', url }), httpLayer, credLayer)
    const second = await runOnce(fetchAsset({ project: 'p', url }), httpLayer, credLayer)

    expect(second).toEqual(first)
    expect(calls).toHaveLength(1)
  })

  test('the cache filename extension is inferred from the response content-type', async () => {
    const cases: ReadonlyArray<readonly [string | undefined, string]> = [
      ['image/png', '.png'],
      ['image/jpeg', '.jpg'],
      ['image/gif', '.gif'],
      ['image/webp', '.webp'],
      [undefined, '.img'],
    ]
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))

    for (const [contentType, expectedExt] of cases) {
      const { layer: httpLayer } = testHttpClient(
        () =>
          new Response(new Uint8Array([1]), {
            status: 200,
            headers: contentType !== undefined ? { 'content-type': contentType } : {},
          }),
      )
      const url = `https://i.gyazo.com/${expectedExt.slice(1)}.bin`
      const result = await runOnce(fetchAsset({ project: 'p', url }), httpLayer, credLayer)
      expect(result.ok).toBe(true)
      if (result.ok) expect(result.path.endsWith(expectedExt)).toBe(true)
    }
  })

  test('an SVG that cannot be rasterized reports why instead of a path nothing can draw', async () => {
    // Terminal graphics composite raster formats only, so handing back the .svg
    // would leave the backend silently drawing nothing.
    const { layer: httpLayer } = testHttpClient(
      () =>
        new Response(new Uint8Array([1]), {
          status: 200,
          headers: { 'content-type': 'image/svg+xml' },
        }),
    )
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const result = await runOnce(
      fetchAsset({ project: 'p', url: 'https://i.gyazo.com/broken.svg' }),
      httpLayer,
      credLayer,
    )
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.message).toContain('librsvg')
  })

  test('the credential header is attached only for a same-origin URL', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() => png(3))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))

    await runOnce(
      fetchAsset({ project: 'p', url: `${ORIGIN}/api/pages/p/Icon/icon` }),
      httpLayer,
      credLayer,
    )
    await runOnce(
      fetchAsset({ project: 'p', url: 'https://i.gyazo.com/off-origin.png' }),
      httpLayer,
      credLayer,
    )

    expect(headerOf(calls[0], 'x-personal-access-token')).toBe(PAT.value)
    expect(headerOf(calls[1], 'x-personal-access-token')).toBeUndefined()
  })

  test('a redirect leaving the session origin drops the credential header on the following hop', async () => {
    const iconUrl = `${ORIGIN}/api/pages/p/Icon/icon`
    const gcsUrl = 'https://storage.googleapis.com/bucket/icon.png'
    const { layer: httpLayer, calls } = testHttpClient((url) =>
      url === iconUrl ? new Response(null, { status: 302, headers: { location: gcsUrl } }) : png(4),
    )
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))

    const result = await runOnce(fetchAsset({ project: 'p', url: iconUrl }), httpLayer, credLayer)

    expect(result.ok).toBe(true)
    expect(calls).toHaveLength(2)
    expect(calls[0]?.url).toBe(iconUrl)
    expect(headerOf(calls[0], 'x-personal-access-token')).toBe(PAT.value)
    expect(calls[1]?.url).toBe(gcsUrl)
    expect(headerOf(calls[1], 'x-personal-access-token')).toBeUndefined()
  })

  test('gives up after too many redirects', async () => {
    const { layer: httpLayer, calls } = testHttpClient((url) => {
      const next = `${url}/x`
      return new Response(null, { status: 302, headers: { location: next } })
    })
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))

    const result = await runOnce(
      fetchAsset({ project: 'p', url: 'https://i.gyazo.com/loop' }),
      httpLayer,
      credLayer,
    )

    expect(result).toEqual({ ok: false, code: 'error', message: 'too many redirects' })
    expect(calls).toHaveLength(4) // initial request + 3 followed redirects, then give up
  })

  test('a non-2xx final response maps to an error envelope', async () => {
    const { layer: httpLayer } = testHttpClient(() => new Response('boom', { status: 500 }))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))

    const result = await runOnce(
      fetchAsset({ project: 'p', url: 'https://i.gyazo.com/broken.png' }),
      httpLayer,
      credLayer,
    )

    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.code).toBe('error')
  })

  test('401/403 map to code "unauthorized" without leaking the credential', async () => {
    const { layer: httpLayer } = testHttpClient(() => new Response('nope', { status: 403 }))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))

    const result = await runOnce(
      fetchAsset({ project: 'p', url: `${ORIGIN}/api/pages/p/Private/icon` }),
      httpLayer,
      credLayer,
    )

    expect(result.ok).toBe(false)
    if (!result.ok) {
      expect(result.code).toBe('unauthorized')
      expect(result.message).not.toContain(PAT.value)
    }
  })

  test('an off-origin URL never receives the credential header, even without a redirect', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() => png(5))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))

    await runOnce(
      fetchAsset({ project: 'p', url: 'https://i.gyazo.com/plain.png' }),
      httpLayer,
      credLayer,
    )

    expect(headerOf(calls[0], 'x-personal-access-token')).toBeUndefined()
  })

  test('concurrent fetchAsset calls for the same URL are deduped into one request', async () => {
    const { layer: httpLayer, calls } = testHttpClient(() => png(6))
    const { layer: credLayer } = testCredentialStore(Option.some(PAT))
    const url = 'https://i.gyazo.com/shared.png'

    const program = Effect.all(
      [fetchAsset({ project: 'p', url }), fetchAsset({ project: 'p', url })],
      { concurrency: 'unbounded' },
    )
    const [first, second] = await runOnce(program, httpLayer, credLayer)

    expect(first).toEqual(second)
    expect(first.ok).toBe(true)
    expect(calls).toHaveLength(1)
  })
})
