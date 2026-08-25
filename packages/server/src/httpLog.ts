import { HttpClient, HttpClientLive } from '@chatora/core'
import { Effect, Layer } from 'effect'
import { log } from './log'

const OK_MIN = 200
const OK_MAX = 300

// Credentials travel in headers, never the URL, so a URL is safe to record. A query string
// is not: `?q=` carries whatever was typed into the search box.
const withoutQuery = (url: string): string => {
  const at = url.indexOf('?')
  return at === -1 ? url : url.slice(0, at)
}

/**
 * `HttpClientLive` with every non-2xx response recorded to the diagnostic log.
 *
 * The layers above this one turn a failed request into a value — a page that reads as
 * absent, an image that quietly does not appear — which is right for the UI and leaves
 * nothing to explain it. One line here covers every route at once, so "it did not load"
 * always has an answer behind `log = true`.
 */
export const HttpClientLogged: Layer.Layer<HttpClient> = Layer.succeed(
  HttpClient,
  HttpClient.of({
    fetch: (input, init) =>
      HttpClient.pipe(
        Effect.flatMap((client) => client.fetch(input, init)),
        Effect.tap((response) =>
          response.status >= OK_MIN && response.status < OK_MAX
            ? Effect.void
            : log('warn', 'request failed', {
                method: init.method ?? 'GET',
                url: withoutQuery(input),
                status: response.status,
              }),
        ),
        Effect.tapError((error) =>
          log('warn', 'request could not be sent', {
            method: init.method ?? 'GET',
            url: withoutQuery(input),
            detail: String(error.cause),
          }),
        ),
        Effect.provide(HttpClientLive),
      ),
  }),
)
