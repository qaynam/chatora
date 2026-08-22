import { Effect, Option } from 'effect'
import type { CommandExecutorShape } from './commandExecutor'
import { KeychainError } from './errors'

const SERVICE = 'chatora'

/**
 * `security find-generic-password -s chatora -a <origin> -w`.
 * Soft-fails to `Option.none` — missing item, non-darwin, or any other failing
 * `security` invocation are all "no credential here", not an error to propagate.
 */
export const findGenericPassword = (
  origin: string,
  executor: CommandExecutorShape,
): Effect.Effect<Option.Option<string>> => {
  if (process.platform !== 'darwin') return Effect.succeed(Option.none())
  return executor
    .execFile('security', ['find-generic-password', '-s', SERVICE, '-a', origin, '-w'])
    .pipe(
      Effect.map(({ stdout }) => {
        const value = stdout.trim()
        return value === '' ? Option.none() : Option.some(value)
      }),
      Effect.catchAll(() => Effect.succeed(Option.none())),
    )
}

/** `security add-generic-password -U -s chatora -a <origin> -w <pat>`. Args array only, never a shell string. */
export const addGenericPassword = (
  origin: string,
  pat: string,
  executor: CommandExecutorShape,
): Effect.Effect<void, KeychainError> => {
  if (process.platform !== 'darwin') {
    return Effect.fail(new KeychainError({ message: 'macOS Keychain is only available on darwin' }))
  }
  return executor
    .execFile('security', ['add-generic-password', '-U', '-s', SERVICE, '-a', origin, '-w', pat])
    .pipe(
      Effect.asVoid,
      Effect.mapError(
        (cause) =>
          new KeychainError({
            message: `Failed to store credential in Keychain for ${origin}`,
            cause,
          }),
      ),
    )
}

/** `security delete-generic-password -s chatora -a <origin>`. */
export const deleteGenericPassword = (
  origin: string,
  executor: CommandExecutorShape,
): Effect.Effect<void, KeychainError> => {
  if (process.platform !== 'darwin') {
    return Effect.fail(new KeychainError({ message: 'macOS Keychain is only available on darwin' }))
  }
  return executor
    .execFile('security', ['delete-generic-password', '-s', SERVICE, '-a', origin])
    .pipe(
      Effect.asVoid,
      Effect.mapError(
        (cause) =>
          new KeychainError({
            message: `Failed to delete credential from Keychain for ${origin}`,
            cause,
          }),
      ),
    )
}
