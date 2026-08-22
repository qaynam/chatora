import { Context, Effect, Layer, Option } from 'effect'
import { CommandExecutor } from './commandExecutor'
import type { KeychainError } from './errors'
import { addGenericPassword, deleteGenericPassword, findGenericPassword } from './keychain'

export type CredentialSource = 'env' | 'keychain'
// 'serviceAccount' has no resolver in this package right now — cosense-cli's
// settings.json (the only source that ever produced one) was dropped in favor of
// chatora managing credentials itself. The variant stays so header-building
// (x-service-account-access-key vs x-personal-access-token) and any future source can
// keep using one `Credential` shape without a breaking change.
export type CredentialType = 'pat' | 'serviceAccount'

export interface Credential {
  readonly type: CredentialType
  readonly value: string
  readonly source: CredentialSource
}

const readEnvCredential = (): Option.Option<Credential> => {
  const raw = process.env.COSENSE_PAT
  if (typeof raw !== 'string') return Option.none()
  const value = raw.trim()
  return value === '' ? Option.none() : Option.some({ type: 'pat', value, source: 'env' })
}

export interface CredentialStoreShape {
  /** Resolution order: env `COSENSE_PAT`, then macOS Keychain (service "chatora", account = origin). */
  readonly resolve: (origin: string) => Effect.Effect<Option.Option<Credential>>
  /** Login storage is Keychain-only. */
  readonly store: (origin: string, pat: string) => Effect.Effect<void, KeychainError>
  readonly remove: (origin: string) => Effect.Effect<void, KeychainError>
}

export class CredentialStore extends Context.Tag('@chatora/core/CredentialStore')<
  CredentialStore,
  CredentialStoreShape
>() {}

export const CredentialStoreLive: Layer.Layer<CredentialStore, never, CommandExecutor> =
  Layer.effect(
    CredentialStore,
    Effect.gen(function* () {
      const executor = yield* CommandExecutor

      const resolve: CredentialStoreShape['resolve'] = (origin) => {
        const env = readEnvCredential()
        if (Option.isSome(env)) return Effect.succeed(env)
        return findGenericPassword(origin, executor).pipe(
          Effect.map(
            Option.map((value): Credential => ({ type: 'pat', value, source: 'keychain' })),
          ),
        )
      }

      return CredentialStore.of({
        resolve,
        store: (origin, pat) => addGenericPassword(origin, pat, executor),
        remove: (origin) => deleteGenericPassword(origin, executor),
      })
    }),
  )
