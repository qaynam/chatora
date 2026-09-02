import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Effect, Layer, Option } from 'effect'
import { type Account, AccountStore, AccountStoreLive } from './accounts'
import { CommandExecutor, type CommandExecutorShape } from './commandExecutor'
import { CommandExecutorError } from './errors'

const account: Account = {
  id: 'https://scrapbox.io#u1',
  origin: 'https://scrapbox.io',
  userId: 'u1',
  name: 'qaynam',
  displayName: 'Qaynam',
}

const accountB: Account = {
  id: 'https://scrapbox.io#u2',
  origin: 'https://scrapbox.io',
  userId: 'u2',
  name: 'qaynam',
  displayName: 'Qaynam',
  photo: 'https://example.com/qaynam.png',
}

// Answers find/add/delete-generic-password from an in-memory map keyed by the `-a` account,
// standing in for a real Keychain across a sequence of AccountStore calls in one test.
const fakeKeychainExecutor = (): {
  executor: CommandExecutorShape
  calls: { file: string; args: readonly string[] }[]
} => {
  const store = new Map<string, string>()
  const calls: { file: string; args: readonly string[] }[] = []
  const argAfter = (args: readonly string[], flag: string): string | undefined =>
    args[args.indexOf(flag) + 1]

  return {
    calls,
    executor: {
      execFile: (file, args) => {
        calls.push({ file, args })
        switch (args[0]) {
          case 'find-generic-password': {
            const value = store.get(argAfter(args, '-a') ?? '')
            return value === undefined
              ? Effect.fail(new CommandExecutorError({ command: file, args, cause: 'not found' }))
              : Effect.succeed({ stdout: value, stderr: '' })
          }
          case 'add-generic-password': {
            const acc = argAfter(args, '-a')
            const pat = argAfter(args, '-w')
            if (acc !== undefined && pat !== undefined) store.set(acc, pat)
            return Effect.succeed({ stdout: '', stderr: '' })
          }
          case 'delete-generic-password': {
            const acc = argAfter(args, '-a')
            if (acc !== undefined) store.delete(acc)
            return Effect.succeed({ stdout: '', stderr: '' })
          }
          default:
            return Effect.succeed({ stdout: '', stderr: '' })
        }
      },
    },
  }
}

const withDarwin = <T>(fn: () => T): T => {
  const original = process.platform
  Object.defineProperty(process, 'platform', { value: 'darwin' })
  try {
    return fn()
  } finally {
    Object.defineProperty(process, 'platform', { value: original })
  }
}

const run = <A, E>(
  program: Effect.Effect<A, E, AccountStore>,
  executor: CommandExecutorShape,
): Promise<A> =>
  Effect.runPromise(
    program.pipe(
      Effect.provide(
        AccountStoreLive.pipe(Layer.provide(Layer.succeed(CommandExecutor, executor))),
      ),
    ),
  )

// The store reaches macOS Keychain for the PAT, and the implementation refuses outright on
// anything else — so on another platform there is nothing here to exercise.
describe.skipIf(process.platform !== 'darwin')('AccountStore', () => {
  let stateDir: string
  let originalStateDir: string | undefined

  beforeEach(() => {
    originalStateDir = process.env.CHATORA_STATE_DIR
    stateDir = mkdtempSync(join(tmpdir(), 'chatora-accounts-'))
    process.env.CHATORA_STATE_DIR = stateDir
  })

  afterEach(() => {
    if (originalStateDir === undefined) delete process.env.CHATORA_STATE_DIR
    else process.env.CHATORA_STATE_DIR = originalStateDir
    rmSync(stateDir, { recursive: true, force: true })
  })

  test('list() is empty before any account has been added', async () => {
    const { executor } = fakeKeychainExecutor()
    const result = await withDarwin(() =>
      run(
        Effect.gen(function* () {
          const store = yield* AccountStore
          return yield* store.list()
        }),
        executor,
      ),
    )
    expect(result).toEqual({ active: Option.none(), accounts: [] })
  })

  test('add() stores the PAT in Keychain under the account id, upserts the index, and activates it', async () => {
    const { executor, calls } = fakeKeychainExecutor()
    const result = await withDarwin(() =>
      run(
        Effect.gen(function* () {
          const store = yield* AccountStore
          yield* store.add(account, 'pat-1')
          return yield* store.list()
        }),
        executor,
      ),
    )
    expect(result).toEqual({ active: Option.some(account.id), accounts: [account] })
    expect(
      calls.some((c) => c.args[0] === 'add-generic-password' && c.args.includes(account.id)),
    ).toBe(true)

    const onDisk: unknown = JSON.parse(readFileSync(join(stateDir, 'accounts.json'), 'utf8'))
    expect(onDisk).toEqual({ active: account.id, accounts: [account] })
  })

  test('writes the index file with mode 0600', async () => {
    const { executor } = fakeKeychainExecutor()
    await withDarwin(() =>
      run(
        Effect.gen(function* () {
          const store = yield* AccountStore
          yield* store.add(account, 'pat-1')
        }),
        executor,
      ),
    )
    const mode = statSync(join(stateDir, 'accounts.json')).mode & 0o777
    expect(mode).toBe(0o600)
  })

  test('add() upserts an existing account instead of duplicating it', async () => {
    const { executor } = fakeKeychainExecutor()
    const updated: Account = { ...account, displayName: 'Qaynam (renamed)' }
    const result = await withDarwin(() =>
      run(
        Effect.gen(function* () {
          const store = yield* AccountStore
          yield* store.add(account, 'pat-1')
          yield* store.add(updated, 'pat-2')
          return yield* store.list()
        }),
        executor,
      ),
    )
    expect(result.accounts).toEqual([updated])
  })

  test('remove() reassigns active to the first remaining account', async () => {
    const { executor } = fakeKeychainExecutor()
    const result = await withDarwin(() =>
      run(
        Effect.gen(function* () {
          const store = yield* AccountStore
          yield* store.add(account, 'pat-1')
          yield* store.add(accountB, 'pat-2')
          yield* store.remove(accountB.id)
          return yield* store.list()
        }),
        executor,
      ),
    )
    expect(result).toEqual({ active: Option.some(account.id), accounts: [account] })
  })

  test('remove() clears active when no accounts remain', async () => {
    const { executor } = fakeKeychainExecutor()
    const result = await withDarwin(() =>
      run(
        Effect.gen(function* () {
          const store = yield* AccountStore
          yield* store.add(account, 'pat-1')
          yield* store.remove(account.id)
          return yield* store.list()
        }),
        executor,
      ),
    )
    expect(result).toEqual({ active: Option.none(), accounts: [] })
  })

  test('setActive() returns Option.none for an unknown id and leaves the index untouched', async () => {
    const { executor } = fakeKeychainExecutor()
    const [setResult, listResult] = await withDarwin(() =>
      run(
        Effect.gen(function* () {
          const store = yield* AccountStore
          yield* store.add(account, 'pat-1')
          const set = yield* store.setActive('unknown-id')
          const list = yield* store.list()
          return [set, list] as const
        }),
        executor,
      ),
    )
    expect(setResult).toEqual(Option.none())
    expect(listResult).toEqual({ active: Option.some(account.id), accounts: [account] })
  })

  test('setActive() switches the active account and returns it', async () => {
    const { executor } = fakeKeychainExecutor()
    const [setResult, listResult] = await withDarwin(() =>
      run(
        Effect.gen(function* () {
          const store = yield* AccountStore
          yield* store.add(account, 'pat-1')
          yield* store.add(accountB, 'pat-2')
          const set = yield* store.setActive(account.id)
          const list = yield* store.list()
          return [set, list] as const
        }),
        executor,
      ),
    )
    expect(setResult).toEqual(Option.some(account))
    expect(listResult.active).toEqual(Option.some(account.id))
  })

  test('resolveActive() reads the active account PAT from Keychain when origins match', async () => {
    const { executor } = fakeKeychainExecutor()
    const pat = await withDarwin(() =>
      run(
        Effect.gen(function* () {
          const store = yield* AccountStore
          yield* store.add(account, 'pat-1')
          return yield* store.resolveActive(account.origin)
        }),
        executor,
      ),
    )
    expect(pat).toEqual(Option.some('pat-1'))
  })

  test('resolveActive() returns Option.none when the active account is for a different origin', async () => {
    const { executor } = fakeKeychainExecutor()
    const pat = await withDarwin(() =>
      run(
        Effect.gen(function* () {
          const store = yield* AccountStore
          yield* store.add(account, 'pat-1')
          return yield* store.resolveActive('https://other.example')
        }),
        executor,
      ),
    )
    expect(pat).toEqual(Option.none())
  })

  test('resolveActive() returns Option.none when there is no active account', async () => {
    const { executor } = fakeKeychainExecutor()
    const pat = await withDarwin(() =>
      run(
        Effect.gen(function* () {
          const store = yield* AccountStore
          return yield* store.resolveActive('https://scrapbox.io')
        }),
        executor,
      ),
    )
    expect(pat).toEqual(Option.none())
  })

  test('a corrupt index file is treated as empty instead of failing', async () => {
    mkdirSync(stateDir, { recursive: true })
    writeFileSync(join(stateDir, 'accounts.json'), '{not json')
    const { executor } = fakeKeychainExecutor()
    const result = await withDarwin(() =>
      run(
        Effect.gen(function* () {
          const store = yield* AccountStore
          return yield* store.list()
        }),
        executor,
      ),
    )
    expect(result).toEqual({ active: Option.none(), accounts: [] })
  })
})
