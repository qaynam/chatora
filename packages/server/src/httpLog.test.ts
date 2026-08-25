import { describe, expect, test } from 'bun:test'
import { HttpClient } from '@chatora/core'
import { Effect } from 'effect'
import { HttpClientLogged } from './httpLog'

/** Runs one request through the logging layer against a stubbed global fetch. */
const request = async (respond: () => Response | Promise<Response>, url = 'https://x/api/y') => {
  const original = globalThis.fetch
  globalThis.fetch = (async () => await respond()) as unknown as typeof fetch
  try {
    return await Effect.runPromise(
      HttpClient.pipe(
        Effect.flatMap((client) => client.fetch(url, {})),
        Effect.provide(HttpClientLogged),
      ),
    )
  } finally {
    globalThis.fetch = original
  }
}

describe('HttpClientLogged', () => {
  // Logging is off in tests (CHATORA_LOG unset), so what matters here is that wrapping the
  // client leaves its contract untouched: the response passes through, and a non-2xx is
  // still a success at this layer for CosenseApi to interpret.
  test('passes a success through', async () => {
    const response = await request(() => new Response('ok', { status: 200 }))
    expect(response.status).toBe(200)
    expect(await response.text()).toBe('ok')
  })

  test('a non-2xx is still a resolved response, not a failure', async () => {
    const response = await request(() => new Response('nope', { status: 401 }))
    expect(response.status).toBe(401)
  })

  test('a rejected fetch still fails', async () => {
    const original = globalThis.fetch
    globalThis.fetch = (() => Promise.reject(new Error('down'))) as unknown as typeof fetch
    try {
      const result = await Effect.runPromise(
        Effect.either(
          HttpClient.pipe(
            Effect.flatMap((client) => client.fetch('https://x/boom', {})),
            Effect.provide(HttpClientLogged),
          ),
        ),
      )
      expect(result._tag).toBe('Left')
    } finally {
      globalThis.fetch = original
    }
  })
})
