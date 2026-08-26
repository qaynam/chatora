import { describe, expect, test } from 'bun:test'
import { Effect, Option } from 'effect'
import { isGyazoUrl, resolveGyazo } from './gyazo'

const ORIGIN = 'https://scrapbox.io'

// A resolution is remembered for the life of the process, so every test here (and in
// assets.test.ts) works on a URL of its own — a shared one would be answered from the cache
// a previous test filled.

const oembed = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

/** A fetch that records what it was asked for and answers from `handler`. */
const testFetch = (handler: (url: string) => Response) => {
  const calls: string[] = []
  return {
    calls,
    fetch: (url: string) => {
      calls.push(url)
      return Effect.sync(() => handler(url))
    },
  }
}

const run = <A>(effect: Effect.Effect<A>): Promise<A> => Effect.runPromise(effect)

describe('isGyazoUrl', () => {
  test.each([
    ['https://gyazo.com/0204f06d4ed4af1554dc3c2a87a806b2', true],
    ['https://i.gyazo.com/0204f06d4ed4af1554dc3c2a87a806b2.png', true],
    ['https://myteam.gyazo.com/d5a22192d87effa875686051a0c5a179', true],
    ['https://t.gyazo.com/teams/myteam/d5a22192.png', true],
    ['https://example.com/gyazo.com/x.png', false],
    ['https://notgyazo.com/x', false],
    ['gyazo.com/x', false],
    ['javascript:alert(1)', false],
  ])('%s -> %s', (url, expected) => {
    expect(isGyazoUrl(url)).toBe(expected)
  })
})

describe('resolveGyazo', () => {
  test('a photo resolves to the URL the proxy names, team hosts included', async () => {
    const url = 'https://myteam.gyazo.com/d5a22192d87effa875686051a0c5a179'
    const picture = 'https://t.gyazo.com/teams/myteam/d5a22192d87effa875686051a0c5a179.png'
    const { fetch, calls } = testFetch(() =>
      oembed({ version: '1.0', type: 'photo', url: picture, width: 1500, height: 1301 }),
    )
    expect(await run(resolveGyazo(fetch, ORIGIN, url))).toEqual(Option.some({ still: picture }))
    expect(calls[0]).toBe(`${ORIGIN}/api/oembed-proxy/gyazo?url=${encodeURIComponent(url)}`)
  })

  test('an animated capture draws as its still and plays from its own mp4', async () => {
    const hash = 'aaaaaaaaaaaaaaaaaaaaaaaa'
    const thumb = 'https://thumb.gyazo.com/thumb/700_w/eyJhbGciOiJIUzI1NiJ9-gif.jpg'
    const { fetch } = testFetch(() =>
      oembed({
        type: 'video',
        html: `<iframe src="https://gyazo.com/player/${hash}"></iframe>`,
        thumbnail_url: thumb,
      }),
    )
    expect(await run(resolveGyazo(fetch, ORIGIN, `https://gyazo.com/${hash}`))).toEqual(
      Option.some({ still: thumb, play: `https://i.gyazo.com/${hash}.mp4` }),
    )
  })

  test("a team's capture has no mp4 to guess, so its player page is what plays", async () => {
    const hash = 'bbbbbbbbbbbbbbbbbbbbbbbb'
    const player = `https://myteam.gyazo.com/player/${hash}`
    const { fetch } = testFetch(() =>
      oembed({
        type: 'video',
        html: `<iframe\n  src="${player}"\n  width="480">\n</iframe>`,
        thumbnail_url: 'https://t.gyazo.com/teams/myteam/thumb/480_w/x-gif.jpg',
      }),
    )
    const media = await run(resolveGyazo(fetch, ORIGIN, `https://myteam.gyazo.com/${hash}`))
    expect(Option.getOrNull(media)?.play).toBe(player)
  })

  test('a photo has nothing to play', async () => {
    const { fetch } = testFetch(() => oembed({ type: 'photo', url: 'https://i.gyazo.com/p.png' }))
    expect(
      await run(resolveGyazo(fetch, ORIGIN, 'https://gyazo.com/cccccccccccccccccccccccd')),
    ).toEqual(Option.some({ still: 'https://i.gyazo.com/p.png' }))
  })

  test('one answer stands for the session: the proxy is asked once per URL', async () => {
    const url = 'https://gyazo.com/bbbbbbbbbbbbbbbbbbbbbbbb'
    const { fetch, calls } = testFetch(() =>
      oembed({ type: 'photo', url: 'https://i.gyazo.com/b.png' }),
    )
    await run(resolveGyazo(fetch, ORIGIN, url))
    await run(resolveGyazo(fetch, ORIGIN, url))
    expect(calls).toHaveLength(1)
  })

  test.each([
    ['a URL that is not Gyazo at all', 'https://example.com/a.png', () => oembed({}, 200)],
    [
      'a proxy that refuses it',
      'https://gyazo.com/cccccccccccccccccccccccc',
      () => oembed({}, 422),
    ],
    [
      'an answer naming no picture',
      'https://gyazo.com/dddddddddddddddddddddddd',
      () => oembed({ type: 'video', html: '<iframe/>' }),
    ],
    [
      'a body that is not the shape it should be',
      'https://gyazo.com/eeeeeeeeeeeeeeeeeeeeeeee',
      () => new Response('<html/>', { status: 200 }),
    ],
  ])('%s resolves to nothing, leaving the caller its own URL', async (_label, url, handler) => {
    const { fetch } = testFetch(handler)
    expect(await run(resolveGyazo(fetch, ORIGIN, url))).toEqual(Option.none())
  })

  test('a failure is not remembered: the proxy is asked again next time', async () => {
    const url = 'https://gyazo.com/ffffffffffffffffffffffff'
    let failing = true
    const { fetch, calls } = testFetch(() =>
      failing ? oembed({}, 500) : oembed({ type: 'photo', url: 'https://i.gyazo.com/f.png' }),
    )
    expect(await run(resolveGyazo(fetch, ORIGIN, url))).toEqual(Option.none())
    failing = false
    expect(await run(resolveGyazo(fetch, ORIGIN, url))).toEqual(
      Option.some({ still: 'https://i.gyazo.com/f.png' }),
    )
    expect(calls).toHaveLength(2)
  })
})
