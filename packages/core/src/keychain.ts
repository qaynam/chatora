import { Effect, Option } from 'effect'
import type { CommandExecutorShape } from './commandExecutor'
import { KeychainError } from './errors'

const SERVICE = 'chatora'

/**
 * `security find-generic-password -s chatora -a <account> -w`. `account` is the Keychain
 * item's `-a` value — an origin for the legacy per-origin entries, or an `Account.id`
 * (`${origin}#${userId}`) for a multi-account entry.
 * Soft-fails to `Option.none` — missing item, non-darwin, or any other failing
 * `security` invocation are all "no credential here", not an error to propagate.
 */
export const findGenericPassword = (
  account: string,
  executor: CommandExecutorShape,
): Effect.Effect<Option.Option<string>> => {
  if (process.platform !== 'darwin') return Effect.succeed(Option.none())
  return executor
    .execFile('security', ['find-generic-password', '-s', SERVICE, '-a', account, '-w'])
    .pipe(
      Effect.map(({ stdout }) => {
        const value = stdout.trim()
        return value === '' ? Option.none() : Option.some(value)
      }),
      Effect.catchAll(() => Effect.succeed(Option.none())),
    )
}

/** `security add-generic-password -U -s chatora -a <account> -w <pat>`. Args array only, never a shell string. */
export const addGenericPassword = (
  account: string,
  pat: string,
  executor: CommandExecutorShape,
): Effect.Effect<void, KeychainError> => {
  if (process.platform !== 'darwin') {
    return Effect.fail(new KeychainError({ message: 'macOS Keychain is only available on darwin' }))
  }
  return executor
    .execFile('security', ['add-generic-password', '-U', '-s', SERVICE, '-a', account, '-w', pat])
    .pipe(
      Effect.asVoid,
      Effect.mapError(
        (cause) =>
          new KeychainError({
            message: `Failed to store credential in Keychain for ${account}`,
            cause,
          }),
      ),
    )
}

/** `security delete-generic-password -s chatora -a <account>`. */
export const deleteGenericPassword = (
  account: string,
  executor: CommandExecutorShape,
): Effect.Effect<void, KeychainError> => {
  if (process.platform !== 'darwin') {
    return Effect.fail(new KeychainError({ message: 'macOS Keychain is only available on darwin' }))
  }
  return executor
    .execFile('security', ['delete-generic-password', '-s', SERVICE, '-a', account])
    .pipe(
      Effect.asVoid,
      Effect.mapError(
        (cause) =>
          new KeychainError({
            message: `Failed to delete credential from Keychain for ${account}`,
            cause,
          }),
      ),
    )
}
