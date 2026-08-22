import { describe, expect, test } from 'bun:test'
import { Effect, Option } from 'effect'
import type { CommandExecutorShape } from './commandExecutor'
import { CommandExecutorError } from './errors'
import { addGenericPassword, deleteGenericPassword, findGenericPassword } from './keychain'

const withPlatform = async <T>(platform: NodeJS.Platform, fn: () => Promise<T>): Promise<T> => {
  const original = process.platform
  Object.defineProperty(process, 'platform', { value: platform })
  try {
    return await fn()
  } finally {
    Object.defineProperty(process, 'platform', { value: original })
  }
}

const recordingExecutor = (
  handler: (file: string, args: readonly string[]) => { stdout: string; stderr: string },
): { executor: CommandExecutorShape; calls: { file: string; args: readonly string[] }[] } => {
  const calls: { file: string; args: readonly string[] }[] = []
  return {
    calls,
    executor: {
      execFile: (file, args) => {
        calls.push({ file, args })
        return Effect.succeed(handler(file, args))
      },
    },
  }
}

describe('keychain (darwin)', () => {
  test('findGenericPassword calls security with the expected arg array and trims stdout', async () => {
    const { executor, calls } = recordingExecutor(() => ({ stdout: 'my-pat-value\n', stderr: '' }))
    const value = await withPlatform('darwin', () =>
      Effect.runPromise(findGenericPassword('https://scrapbox.io', executor)),
    )
    expect(value).toEqual(Option.some('my-pat-value'))
    expect(calls).toEqual([
      {
        file: 'security',
        args: ['find-generic-password', '-s', 'chatora', '-a', 'https://scrapbox.io', '-w'],
      },
    ])
  })

  test('findGenericPassword returns Option.none when the item is not found', async () => {
    const executor: CommandExecutorShape = {
      execFile: (file, args) =>
        Effect.fail(
          new CommandExecutorError({
            command: file,
            args,
            cause: new Error(
              'security: SecKeychainSearchCopyNext: The specified item could not be found',
            ),
          }),
        ),
    }
    const value = await withPlatform('darwin', () =>
      Effect.runPromise(findGenericPassword('https://scrapbox.io', executor)),
    )
    expect(value).toEqual(Option.none())
  })

  test('addGenericPassword passes the PAT as a single argv element, never a shell string', async () => {
    const pat = 'sneaky-value; rm -rf /'
    const { executor, calls } = recordingExecutor(() => ({ stdout: '', stderr: '' }))
    await withPlatform('darwin', () =>
      Effect.runPromise(addGenericPassword('https://scrapbox.io', pat, executor)),
    )
    expect(calls).toEqual([
      {
        file: 'security',
        args: [
          'add-generic-password',
          '-U',
          '-s',
          'chatora',
          '-a',
          'https://scrapbox.io',
          '-w',
          pat,
        ],
      },
    ])
    // the raw PAT is a single array element, not interpolated into a joined command string
    expect(calls[0]?.args.at(-1)).toBe(pat)
  })

  test('deleteGenericPassword calls security with the expected arg array', async () => {
    const { executor, calls } = recordingExecutor(() => ({ stdout: '', stderr: '' }))
    await withPlatform('darwin', () =>
      Effect.runPromise(deleteGenericPassword('https://scrapbox.io', executor)),
    )
    expect(calls).toEqual([
      {
        file: 'security',
        args: ['delete-generic-password', '-s', 'chatora', '-a', 'https://scrapbox.io'],
      },
    ])
  })
})

describe('keychain (non-darwin soft-fail)', () => {
  test('findGenericPassword returns Option.none without invoking the executor', async () => {
    let called = false
    const executor: CommandExecutorShape = {
      execFile: () => {
        called = true
        return Effect.succeed({ stdout: '', stderr: '' })
      },
    }
    const value = await withPlatform('linux', () =>
      Effect.runPromise(findGenericPassword('https://scrapbox.io', executor)),
    )
    expect(value).toEqual(Option.none())
    expect(called).toBe(false)
  })

  test('addGenericPassword fails with KeychainError without invoking the executor', async () => {
    let called = false
    const executor: CommandExecutorShape = {
      execFile: () => {
        called = true
        return Effect.succeed({ stdout: '', stderr: '' })
      },
    }
    const exit = await withPlatform('linux', () =>
      Effect.runPromiseExit(addGenericPassword('https://scrapbox.io', 'pat', executor)),
    )
    expect(exit._tag).toBe('Failure')
    expect(called).toBe(false)
  })

  test('deleteGenericPassword fails with KeychainError without invoking the executor', async () => {
    let called = false
    const executor: CommandExecutorShape = {
      execFile: () => {
        called = true
        return Effect.succeed({ stdout: '', stderr: '' })
      },
    }
    const exit = await withPlatform('linux', () =>
      Effect.runPromiseExit(deleteGenericPassword('https://scrapbox.io', executor)),
    )
    expect(exit._tag).toBe('Failure')
    expect(called).toBe(false)
  })
})
