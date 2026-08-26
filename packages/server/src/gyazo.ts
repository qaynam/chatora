import type { HttpClientShape } from '@chatora/core'
import { Effect, Option, Schema } from 'effect'

/**
 * Turning a Gyazo page URL into the picture behind it.
 *
 * There is no guessing it. `https://gyazo.com/<hash>` has a direct form
 * (`https://i.gyazo.com/<hash>.png`) only when the capture is a still image — for the
 * animated ones that form is a 404 — and a team's `https://<team>.gyazo.com/<hash>` has no
 * public form at all. Cosense's web client does not guess either: it asks its own oembed
 * proxy for every Gyazo URL on the page and uses what comes back, and so does this.
 */

const OEMBED_PATH = '/api/oembed-proxy/gyazo?url='

// The fields that name a picture. A photo carries `url`; a video (Gyazo's word for an
// animated capture) carries a still under `thumbnail_url` and an iframe player under
// `html`, which a terminal has no use for.
const OEmbedSchema = Schema.Struct({
  type: Schema.optionalWith(Schema.String, { default: () => '' }),
  url: Schema.optionalWith(Schema.String, { exact: true }),
  thumbnail_url: Schema.optionalWith(Schema.String, { exact: true }),
})

const decode = Schema.decodeUnknownOption(OEmbedSchema)

/**
 * A URL Gyazo serves, by the same test the web client makes: the host itself, or any team
 * under it.
 */
export const isGyazoUrl = (url: string): boolean => {
  try {
    const { hostname, protocol } = new URL(url)
    if (protocol !== 'http:' && protocol !== 'https:') return false
    return hostname === 'gyazo.com' || hostname.endsWith('.gyazo.com')
  } catch {
    return false
  }
}

// A URL's picture never changes, so one answer stands for the session. Failures are not
// cached: a proxy that was unreachable a moment ago is worth asking again.
const resolved = new Map<string, string>()

/**
 * The image URL behind a Gyazo URL, or `Option.none` for anything the proxy cannot name a
 * picture for — which callers answer by fetching the URL they already had.
 */
export const resolveGyazo = (
  fetch: HttpClientShape['fetch'],
  origin: string,
  url: string,
): Effect.Effect<Option.Option<string>> =>
  Effect.gen(function* () {
    if (!isGyazoUrl(url)) return Option.none()
    const cached = resolved.get(url)
    if (cached !== undefined) return Option.some(cached)

    const response = yield* fetch(`${origin}${OEMBED_PATH}${encodeURIComponent(url)}`, {
      method: 'GET',
    }).pipe(Effect.orElseSucceed(() => null))
    if (!response || !response.ok) return Option.none()

    const body = yield* Effect.tryPromise(() => response.json()).pipe(
      Effect.orElseSucceed(() => null),
    )
    const oembed = Option.getOrNull(decode(body))
    if (!oembed) return Option.none()

    const picture = oembed.type === 'video' ? oembed.thumbnail_url : oembed.url
    if (picture === undefined || picture === '') return Option.none()
    resolved.set(url, picture)
    return Option.some(picture)
  })
