import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { Effect, Layer, Option } from 'effect'
import { CommandExecutor } from './commandExecutor'
import { CredentialStore, CredentialStoreLive } from './credentials'
import { CommandExecutorError } from './errors'

const ORIGIN = 'https://scrapbox.io'

const withEnvPat = async <T>(value: string | undefined, fn: () => Promise<T>): Promise<T> => {
  const prev = process.env.COSENSE_PAT
  if (value === undefined) delete process.env.COSENSE_PAT
  else process.env.COSENSE_PAT = value
  try {
    return await fn()
  } finally {
    if (prev === undefined) delete process.env.COSENSE_PAT
    else process.env.COSENSE_PAT = prev
  }
}

const testCommandExecutor = (stdout: string | undefined): Layer.Layer<CommandExecutor> =>
  Layer.succeed(
    CommandExecutor,
    CommandExecutor.of({
      execFile: (file, args) =>
        stdout === undefined
          ? Effect.fail(new CommandExecutorError({ command: file, args, cause: 'not found' }))
          : Effect.succeed({ stdout, stderr: '' }),
    }),
  )

const resolveWith = (stdout: string | undefined, origin = ORIGIN) =>
  Effect.gen(function* () {
    const store = yield* CredentialStore
    return yield* store.resolve(origin)
  }).pipe(Effect.provide(CredentialStoreLive.pipe(Layer.provide(testCommandExecutor(stdout)))))

describe('CredentialStore.resolve precedence: env > keychain', () => {
  const originalPlatform = process.platform

  beforeEach(() => {
    Object.defineProperty(process, 'platform', { value: 'darwin' })
  })

  afterEach(() => {
    Object.defineProperty(process, 'platform', { value: originalPlatform })
  })

  test('env COSENSE_PAT wins even when keychain also has an entry', async () => {
    const credential = await withEnvPat('env-pat', () =>
      Effect.runPromise(resolveWith('keychain-pat')),
    )
    expect(credential).toEqual(Option.some({ type: 'pat', value: 'env-pat', source: 'env' }))
  })

  test('falls back to keychain when env is unset', async () => {
    const credential = await withEnvPat(undefined, () =>
      Effect.runPromise(resolveWith('keychain-pat\n')),
    )
    expect(credential).toEqual(
      Option.some({ type: 'pat', value: 'keychain-pat', source: 'keychain' }),
    )
  })

  test('returns Option.none when neither env nor keychain has a matching entry', async () => {
    const credential = await withEnvPat(undefined, () => Effect.runPromise(resolveWith(undefined)))
    expect(credential).toEqual(Option.none())
  })
})
