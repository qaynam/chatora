import { Data } from 'effect'

/**
 * A Cosense API call did not produce a usable response: a non-2xx status, an unexpected
 * 3xx redirect, or a 2xx body that didn't decode into the shape the caller asked for.
 *
 * `status` is always the HTTP status actually received; `0` marks a transport-level
 * failure where no response arrived at all (DNS, connection refused, ...). `code` mirrors
 * the server's `{"error": "..."}` body field when one was present — callers match on it
 * for domain-specific conflicts (`'NotFastForward'`, `'DuplicateTitle'`); a body that
 * failed schema decoding after a 2xx status uses the sentinel `'DecodeError'`.
 *
 * `message` never contains the credential value (docs/ARCHITECTURE.md "セキュリティ / 作法").
 */
export class CosenseApiError extends Data.TaggedError('CosenseApiError')<{
  readonly status: number
  readonly code?: string
  readonly message: string
}> {}

/** A macOS Keychain (`security` binary) operation could not be completed — unavailable platform or a failing invocation. */
export class KeychainError extends Data.TaggedError('KeychainError')<{
  readonly message: string
  readonly cause?: unknown
}> {}

/** A `CommandExecutor.execFile` invocation could not be spawned or exited non-zero. */
export class CommandExecutorError extends Data.TaggedError('CommandExecutorError')<{
  readonly command: string
  readonly args: readonly string[]
  readonly cause: unknown
}> {}

/** `HttpClient.fetch` rejected before a response was received (network failure, invalid URL, ...). */
export class HttpClientError extends Data.TaggedError('HttpClientError')<{
  readonly cause: unknown
}> {}
