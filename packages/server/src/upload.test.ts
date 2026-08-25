import { beforeAll, describe, expect, test } from 'bun:test'
import { mkdtemp, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { Credential } from '@chatora/core'
import { CredentialStore, HttpClient } from '@chatora/core'
import { Effect, Layer, Option } from 'effect'
import { makeSessionStateLayer } from './state'
import { uploadImage } from './upload'

const ORIGIN = 'https://scrapbox.io'
const PAT: Credential = { type: 'pat', value: 'secret-pat', source: 'keychain' }
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])

let imagePath: string
beforeAll(async () => {
  imagePath = join(await mkdtemp(join(tmpdir(), 'chatora-upload-')), 'clip.png')
  await writeFile(imagePath, PNG)
})

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

/** Runs one upload against `routes`, keyed by a substring of the request URL. */
const run = (routes: readonly (readonly [string, (init: RequestInit) => Response])[]) => {
  const calls: { url: string; init: RequestInit }[] = []
  const httpLayer = Layer.succeed(
    HttpClient,
    HttpClient.of({
      fetch: (url, init = {}) => {
        calls.push({ url, init })
        const route = routes.find(([fragment]) => url.includes(fragment))
        return Effect.sync(() =>
          route ? route[1](init) : new Response('unrouted', { status: 404 }),
        )
      },
    }),
  )
  const credentialLayer = Layer.succeed(
    CredentialStore,
    CredentialStore.of({
      resolve: () => Effect.succeed(Option.some(PAT)),
      store: () => Effect.void,
      remove: () => Effect.void,
    }),
  )
  const result = Effect.runPromise(
    uploadImage({ project: 'my-project', title: 'ページ', path: imagePath }).pipe(
      Effect.provide(httpLayer),
      Effect.provide(makeSessionStateLayer(ORIGIN).pipe(Layer.provide(credentialLayer))),
    ),
  )
  return { result, calls }
}

const PROJECT = (uploadImageTo: string, gyazoTeamsName: string | null = null) =>
  ['/api/projects/my-project', () => json({ id: 'proj1', uploadImageTo, gyazoTeamsName })] as const

/** What a PAT sees: settings refused, but `/users` still hands over the project id. */
const PAT_ONLY = [
  ['/api/projects/my-project/users', () => json({ projectId: 'proj1', users: [] })],
  ['/api/projects/my-project', () => new Response('', { status: 401 })],
] as const

const GYAZO_ROUTES = [
  ['/api/login/gyazo/oauth-upload/token', () => json({ token: 'gyazo-token' })],
  ['upload.gyazo.com', () => json({ permalink_url: 'https://gyazo.com/abc' })],
] as const

const GCS_ROUTES = [
  [
    '/upload-request',
    () => json({ signedUrl: 'https://storage.googleapis.com/signed', fileId: 'file1' }),
  ],
  ['storage.googleapis.com', () => new Response('', { status: 200 })],
  ['/verify', () => json({ embedUrl: 'https://scrapbox.io/files/file1.png' })],
] as const

describe('uploadImage destination', () => {
  test("uploadImageTo 'gyazo' -> Gyazo, notation is the permalink", async () => {
    const { result, calls } = run([PROJECT('gyazo'), ...GYAZO_ROUTES])
    expect(await result).toEqual({
      ok: true,
      notation: '[https://gyazo.com/abc]',
      url: 'https://gyazo.com/abc',
    })
    expect(calls.some((c) => c.url.includes('upload.gyazo.com'))).toBe(true)
    expect(calls.some((c) => c.url.includes('/api/gcs/'))).toBe(false)
  })

  test("uploadImageTo 'gcs' -> the project's own storage, notation is the embed URL", async () => {
    const { result, calls } = run([PROJECT('gcs'), ...GCS_ROUTES])
    expect(await result).toEqual({
      ok: true,
      notation: '[https://scrapbox.io/files/file1.png]',
      url: 'https://scrapbox.io/files/file1.png',
    })
    expect(calls.some((c) => c.url.includes('gyazo'))).toBe(false)
    // The bucket is addressed by the project id from the settings, not by its name.
    expect(calls.map((c) => c.url)).toContain(`${ORIGIN}/api/gcs/proj1/upload-request`)
  })

  test('the destination is read per upload, so switching projects switches host', async () => {
    const gyazo = run([PROJECT('gyazo'), ...GYAZO_ROUTES])
    await gyazo.result
    const gcs = run([PROJECT('gcs'), ...GCS_ROUTES])
    await gcs.result
    expect(gyazo.calls.some((c) => c.url.includes('upload.gyazo.com'))).toBe(true)
    expect(gcs.calls.some((c) => c.url.includes('/api/gcs/'))).toBe(true)
  })

  // The case a personal access token is always in: settings 401, so the preference is
  // unknown — and Gyazo, the destination a PAT can never reach, must not be the guess.
  test('settings a PAT cannot read still upload, to the project storage', async () => {
    const { result, calls } = run([...PAT_ONLY, ...GCS_ROUTES, ...GYAZO_ROUTES])
    expect(await result).toMatchObject({ ok: true, url: 'https://scrapbox.io/files/file1.png' })
    expect(calls.some((c) => c.url.includes('gyazo'))).toBe(false)
  })

  test('with neither settings nor a project id, Gyazo is all that is left', async () => {
    const { result } = run([
      ['/api/projects/my-project/users', () => new Response('', { status: 401 })],
      ['/api/projects/my-project', () => new Response('', { status: 401 })],
      ...GYAZO_ROUTES,
    ])
    expect(await result).toMatchObject({ ok: true, url: 'https://gyazo.com/abc' })
  })

  test('gyazoTeamsName reaches the token request', async () => {
    const { result, calls } = run([PROJECT('gyazo', 'acme'), ...GYAZO_ROUTES])
    await result
    const token = calls.find((c) => c.url.includes('oauth-upload/token'))
    expect(token?.url).toContain('gyazoTeamsName=acme')
  })

  // A PAT is rejected by Cosense's Gyazo token endpoint whatever the project asked for,
  // which leaves the project's own storage as the only reachable destination.
  test('a 401 from the Gyazo token endpoint falls back to the project storage', async () => {
    const { result, calls } = run([
      PROJECT('gyazo'),
      ['/api/login/gyazo/oauth-upload/token', () => new Response('', { status: 401 })],
      ...GCS_ROUTES,
    ])
    expect(await result).toMatchObject({ ok: true, url: 'https://scrapbox.io/files/file1.png' })
    expect(calls.some((c) => c.url.includes('/api/gcs/proj1/verify'))).toBe(true)
  })

  test('a failing project storage falls back to Gyazo', async () => {
    const { result } = run([
      PROJECT('gcs'),
      ['/upload-request', () => new Response('', { status: 403 })],
      ...GYAZO_ROUTES,
    ])
    expect(await result).toMatchObject({ ok: true, url: 'https://gyazo.com/abc' })
  })

  test('both destinations failing reports the one the project asked for', async () => {
    const { result } = run([
      PROJECT('gyazo'),
      ['/api/login/gyazo/oauth-upload/token', () => new Response('', { status: 401 })],
      ['/upload-request', () => new Response('', { status: 403 })],
    ])
    expect(await result).toMatchObject({
      ok: false,
      message: 'Gyazo のアップロードトークンを取得できませんでした',
    })
  })
})

describe('uploadImage GCS flow', () => {
  test('all three calls agree on the md5, and the bytes go straight to the signed URL', async () => {
    const bodies: Record<string, unknown> = {}
    const { result, calls } = run([
      PROJECT('gcs'),
      [
        '/upload-request',
        (init) => {
          bodies.uploadRequest = JSON.parse(String(init.body))
          return json({ signedUrl: 'https://storage.googleapis.com/signed', fileId: 'file1' })
        },
      ],
      ['storage.googleapis.com', () => new Response('', { status: 200 })],
      [
        '/verify',
        (init) => {
          bodies.verify = JSON.parse(String(init.body))
          return json({ embedUrl: 'https://scrapbox.io/files/file1.png' })
        },
      ],
    ])
    await result

    const uploadRequest = bodies.uploadRequest as { md5: string; size: number; contentType: string }
    expect(uploadRequest.size).toBe(PNG.length)
    expect(uploadRequest.contentType).toBe('image/png')
    expect(bodies.verify).toEqual({ md5: uploadRequest.md5, fileId: 'file1', pixelRatio: null })

    // Signed for `content-type;host` only: a session header here breaks the signature.
    const put = calls.find((c) => c.url.includes('storage.googleapis.com'))
    expect(put?.init.method).toBe('PUT')
    expect(put?.init.headers).toEqual({ 'Content-Type': 'image/png' })
    expect(put?.init.body).toEqual(PNG)
  })

  test('a failure at any step reports rather than writing a broken notation', async () => {
    const { result } = run([
      PROJECT('gcs'),
      [
        '/upload-request',
        () => json({ signedUrl: 'https://storage.googleapis.com/signed', fileId: 'file1' }),
      ],
      ['storage.googleapis.com', () => new Response('denied', { status: 403 })],
    ])
    expect(await result).toMatchObject({ ok: false, code: 'error' })
  })
})
