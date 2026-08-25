import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { HttpClient } from '@chatora/core'
import { Effect, Option } from 'effect'
import { log } from './log'
import type { ErrEnvelope } from './pages'
import { SessionState } from './state'

export interface UploadResult {
  readonly ok: true
  /** Ready to paste, e.g. `[https://gyazo.com/<id>]`. */
  readonly notation: string
  readonly url: string
}

const GYAZO_UPLOAD_URL = 'https://upload.gyazo.com/api/upload'

const err = (message: string): ErrEnvelope => ({ ok: false, code: 'error', message })

// A host stores whatever it is sent, but the declared content type is what decides how the
// image comes back. Sniffed from the bytes rather than the file name: a screenshot handed
// over by a clipboard tool often has no meaningful extension.
const SIGNATURES: readonly { readonly bytes: readonly number[]; readonly mime: string }[] = [
  { bytes: [0x89, 0x50, 0x4e, 0x47], mime: 'image/png' },
  { bytes: [0xff, 0xd8, 0xff], mime: 'image/jpeg' },
  { bytes: [0x47, 0x49, 0x46, 0x38], mime: 'image/gif' },
  { bytes: [0x52, 0x49, 0x46, 0x46], mime: 'image/webp' },
]

const contentTypeOf = (bytes: Uint8Array): string =>
  SIGNATURES.find((s) => s.bytes.every((b, i) => bytes[i] === b))?.mime ?? 'image/png'

const EXTENSION: Readonly<Record<string, string>> = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/gif': 'gif',
  'image/webp': 'webp',
}

interface GyazoToken {
  readonly token?: string
}
interface GyazoUpload {
  readonly permalink_url?: string
}
interface GcsUploadRequest {
  readonly signedUrl?: string
  readonly fileId?: string
}
interface GcsVerify {
  readonly embedUrl?: string
}

const readJson = (response: Response): Effect.Effect<unknown, never> =>
  Effect.tryPromise(() => response.json()).pipe(Effect.orElseSucceed(() => null))

const succeed = (url: string): UploadResult => ({ ok: true, notation: `[${url}]`, url })

/**
 * Upload to Gyazo, the way the web client does for a project whose `uploadImageTo` is
 * `gyazo`: mint a *Cosense* upload token, then post the bytes to Gyazo with it. The Gyazo
 * request carries no session of its own — the token is the whole authorization.
 *
 * Decoded from `.dev/scrapbox.io(image-upload-throw-gyazo).har`.
 */
const uploadToGyazo = (args: {
  readonly origin: string
  readonly headers: Readonly<Record<string, string>>
  readonly bytes: Uint8Array
  readonly contentType: string
  readonly project: string
  readonly title: string
  readonly gyazoTeamsName: string | null
}): Effect.Effect<UploadResult | ErrEnvelope, never, HttpClient> =>
  Effect.gen(function* () {
    const http = yield* HttpClient
    const teams = encodeURIComponent(args.gyazoTeamsName ?? '')
    const tokenResponse = yield* http
      .fetch(`${args.origin}/api/login/gyazo/oauth-upload/token?gyazoTeamsName=${teams}`, {
        headers: args.headers,
      })
      .pipe(Effect.orElseSucceed(() => null))
    if (tokenResponse === null || !tokenResponse.ok) {
      yield* log('warn', 'gyazo upload token failed', { status: tokenResponse?.status })
      return err('Gyazo のアップロードトークンを取得できませんでした')
    }
    const token = ((yield* readJson(tokenResponse)) as GyazoToken | null)?.token
    if (typeof token !== 'string' || token === '') return err('Gyazo のトークンが空でした')

    const form = new FormData()
    form.append('access_token', token)
    form.append(
      'imagedata',
      new Blob([args.bytes], { type: args.contentType }),
      `image.${EXTENSION[args.contentType] ?? 'png'}`,
    )
    // Both are what the web client sends; they are what Gyazo shows as the image's origin.
    form.append('title', args.title)
    form.append('referer_url', `${args.origin}/${args.project}/${args.title}`)

    const uploaded = yield* http
      .fetch(GYAZO_UPLOAD_URL, { method: 'POST', body: form })
      .pipe(Effect.orElseSucceed(() => null))
    if (uploaded === null || !uploaded.ok) {
      yield* log('warn', 'gyazo upload failed', { status: uploaded?.status })
      return err('Gyazo へのアップロードに失敗しました')
    }
    const permalink = ((yield* readJson(uploaded)) as GyazoUpload | null)?.permalink_url
    if (typeof permalink !== 'string' || permalink === '') {
      return err('Gyazo が画像 URL を返しませんでした')
    }
    yield* log('info', 'image uploaded', { to: 'gyazo', url: permalink })
    return succeed(permalink)
  })

/**
 * Upload to the project's own file storage, for a project whose `uploadImageTo` is `gcs`:
 * ask Cosense to sign a Google Cloud Storage URL, PUT the bytes straight to Google, then
 * tell Cosense the upload landed. The md5 is the object's name on the bucket, so all three
 * calls have to agree on it.
 *
 * Decoded from `.dev/scrapbox.io(image-upload-throw-scrapbox.io).har`.
 */
const uploadToGcs = (args: {
  readonly origin: string
  readonly headers: Readonly<Record<string, string>>
  readonly bytes: Uint8Array
  readonly contentType: string
  readonly projectId: string
}): Effect.Effect<UploadResult | ErrEnvelope, never, HttpClient> =>
  Effect.gen(function* () {
    const http = yield* HttpClient
    const md5 = createHash('md5').update(args.bytes).digest('hex')
    const extension = EXTENSION[args.contentType] ?? 'png'
    const json = { ...args.headers, 'Content-Type': 'application/json' }
    const base = `${args.origin}/api/gcs/${args.projectId}`

    const requested = yield* http
      .fetch(`${base}/upload-request`, {
        method: 'POST',
        headers: json,
        body: JSON.stringify({
          md5,
          size: args.bytes.length,
          contentType: args.contentType,
          name: `file-${md5}.${extension}`,
        }),
      })
      .pipe(Effect.orElseSucceed(() => null))
    if (requested === null || !requested.ok) {
      yield* log('warn', 'gcs upload-request failed', { status: requested?.status })
      return err('アップロード先 URL を取得できませんでした')
    }
    const { signedUrl, fileId } = ((yield* readJson(requested)) as GcsUploadRequest | null) ?? {}
    if (!signedUrl || !fileId) return err('アップロード先 URL が空でした')

    // Signed for exactly `content-type;host`, so sending any other header breaks the
    // signature — in particular the session headers, which Google would reject.
    const stored = yield* http
      .fetch(signedUrl, {
        method: 'PUT',
        headers: { 'Content-Type': args.contentType },
        body: args.bytes,
      })
      .pipe(Effect.orElseSucceed(() => null))
    if (stored === null || !stored.ok) {
      yield* log('warn', 'gcs put failed', { status: stored?.status })
      return err('ストレージへのアップロードに失敗しました')
    }

    // Until this lands the object exists on the bucket but not as a Cosense file, and the
    // embed URL it returns is the only place the public form of that file is spelled out.
    const verified = yield* http
      .fetch(`${base}/verify`, {
        method: 'POST',
        headers: json,
        body: JSON.stringify({ md5, fileId, pixelRatio: null }),
      })
      .pipe(Effect.orElseSucceed(() => null))
    if (verified === null || !verified.ok) {
      yield* log('warn', 'gcs verify failed', { status: verified?.status, fileId })
      return err('アップロードの確定に失敗しました')
    }
    const embedUrl = ((yield* readJson(verified)) as GcsVerify | null)?.embedUrl
    if (typeof embedUrl !== 'string' || embedUrl === '') {
      return err('Cosense が画像 URL を返しませんでした')
    }
    yield* log('info', 'image uploaded', { to: 'gcs', url: embedUrl })
    return succeed(embedUrl)
  })

/**
 * Upload an image and return the notation to write into the page.
 *
 * Two destinations exist, and which one a project wants is its `uploadImageTo` setting —
 * read per upload, so switching projects switches destination with nothing cached to go
 * stale. A personal access token cannot read it, though: plain `/api/projects/<name>`
 * answers a PAT with 401. So the setting is treated as a preference when it can be read
 * and the project's own storage is assumed when it cannot, which is the right guess
 * precisely because the case where it cannot be read is the PAT case — and Cosense's Gyazo
 * token endpoint lives under `/api/login/`, answering to a browser session rather than a
 * token, so a PAT is refused there whatever the project would have preferred.
 *
 * Whichever goes first, the other is tried if it fails.
 */
export const uploadImage = (params: {
  readonly project: string
  readonly title: string
  readonly path: string
}): Effect.Effect<UploadResult | ErrEnvelope, never, SessionState | HttpClient> =>
  Effect.gen(function* () {
    const session = yield* SessionState
    const credential = yield* session.getCredential()
    if (Option.isNone(credential)) return err('not logged in')
    const headers =
      credential.value.type === 'serviceAccount'
        ? { 'x-service-account-access-key': credential.value.value }
        : { 'x-personal-access-token': credential.value.value }

    const bytes = yield* Effect.tryPromise(() => readFile(params.path)).pipe(
      Effect.map((buffer) => new Uint8Array(buffer)),
      Effect.orElseSucceed(() => null),
    )
    if (bytes === null || bytes.length === 0) return err(`cannot read ${params.path}`)
    const contentType = contentTypeOf(bytes)

    const api = yield* session.getApi()
    if (Option.isNone(api)) return err('not logged in')
    const detail = yield* api.value.projectDetail(params.project).pipe(
      Effect.tapError((error) =>
        log('warn', 'project settings unavailable', {
          project: params.project,
          status: error.status,
          detail: error.message,
        }),
      ),
      Effect.orElseSucceed(() => null),
    )
    // `/users` is the project-id route a PAT can take, so the storage upload stays
    // reachable even when the settings above came back 401.
    const projectId =
      detail?.id !== undefined && detail.id !== ''
        ? detail.id
        : (yield* session.getProjectUsers(params.project)).projectId

    const common = { origin: session.origin, headers, bytes, contentType }
    const gcs = projectId !== '' ? () => uploadToGcs({ ...common, projectId }) : null
    const gyazo = () =>
      uploadToGyazo({
        ...common,
        project: params.project,
        title: params.title,
        gyazoTeamsName: detail?.gyazoTeamsName ?? null,
      })

    const [first, second] =
      detail?.uploadImageTo === 'gyazo' || gcs === null ? [gyazo, gcs] : [gcs, gyazo]
    const result = yield* first()
    if (result.ok || second === null) return result
    yield* log('info', 'upload destination failed, trying the other one', {
      project: params.project,
      first: first === gyazo ? 'gyazo' : 'gcs',
    })
    const fallback = yield* second()
    // The first message names the destination the project actually asked for, so it is the
    // more useful one to report when neither worked.
    return fallback.ok ? fallback : result
  })
