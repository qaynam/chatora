import { Context, Effect, Layer } from 'effect'
import { HttpClientError } from './errors'

export interface HttpClientShape {
  /**
   * Performs `fetch(input, init)`, wrapping a rejected fetch (network failure, invalid
   * URL, ...) as `HttpClientError`. Never inspects the resolved `Response`'s status —
   * that's `CosenseApi`'s job — so a non-2xx or 3xx response is still a success here.
   */
  readonly fetch: (input: string, init: RequestInit) => Effect.Effect<Response, HttpClientError>
}

export class HttpClient extends Context.Tag('@chatora/core/HttpClient')<
  HttpClient,
  HttpClientShape
>() {}

export const HttpClientLive: Layer.Layer<HttpClient> = Layer.succeed(
  HttpClient,
  HttpClient.of({
    fetch: (input, init) =>
      Effect.tryPromise({
        try: () => fetch(input, init),
        catch: (cause) => new HttpClientError({ cause }),
      }),
  }),
)
