import { describe, expect, test } from 'bun:test'
import type { ExecFileFn } from './keychain'
import {
  addGenericPassword,
  deleteGenericPassword,
  findGenericPassword,
  KeychainUnavailableError,
} from './keychain'

const withPlatform = async <T>(platform: NodeJS.Platform, fn: () => Promise<T>): Promise<T> => {
  const original = process.platform
  Object.defineProperty(process, 'platform', { value: platform })
  try {
    return await fn()
  } finally {
    Object.defineProperty(process, 'platform', { value: original })
  }
}

describe('keychain (darwin)', () => {
  test('findGenericPassword calls security with the expected arg array and trims stdout', async () => {
    const calls: { file: string; args: string[] }[] = []
    const exec: ExecFileFn = async (file, args) => {
      calls.push({ file, args })
      return { stdout: 'my-pat-value\n', stderr: '' }
    }
    const value = await withPlatform('darwin', () =>
      findGenericPassword('https://scrapbox.io', exec),
    )
    expect(value).toBe('my-pat-value')
    expect(calls).toEqual([
      {
        file: 'security',
        args: ['find-generic-password', '-s', 'chatora', '-a', 'https://scrapbox.io', '-w'],
      },
    ])
  })

  test('findGenericPassword returns null when the item is not found', async () => {
    const exec: ExecFileFn = async () => {
      throw new Error('security: SecKeychainSearchCopyNext: The specified item could not be found')
    }
    const value = await withPlatform('darwin', () =>
      findGenericPassword('https://scrapbox.io', exec),
    )
    expect(value).toBeNull()
  })

  test('addGenericPassword passes the PAT as a single argv element, never a shell string', async () => {
    const calls: { file: string; args: string[] }[] = []
    const pat = 'sneaky-value; rm -rf /'
    const exec: ExecFileFn = async (file, args) => {
      calls.push({ file, args })
      return { stdout: '', stderr: '' }
    }
    await withPlatform('darwin', () => addGenericPassword('https://scrapbox.io', pat, exec))
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
    const calls: { file: string; args: string[] }[] = []
    const exec: ExecFileFn = async (file, args) => {
      calls.push({ file, args })
      return { stdout: '', stderr: '' }
    }
    await withPlatform('darwin', () => deleteGenericPassword('https://scrapbox.io', exec))
    expect(calls).toEqual([
      {
        file: 'security',
        args: ['delete-generic-password', '-s', 'chatora', '-a', 'https://scrapbox.io'],
      },
    ])
  })
})

describe('keychain (non-darwin soft-fail)', () => {
  test('findGenericPassword returns null without invoking exec', async () => {
    let called = false
    const exec: ExecFileFn = async () => {
      called = true
      return { stdout: '', stderr: '' }
    }
    const value = await withPlatform('linux', () =>
      findGenericPassword('https://scrapbox.io', exec),
    )
    expect(value).toBeNull()
    expect(called).toBe(false)
  })

  test('addGenericPassword throws KeychainUnavailableError without invoking exec', async () => {
    let called = false
    const exec: ExecFileFn = async () => {
      called = true
      return { stdout: '', stderr: '' }
    }
    await expect(
      withPlatform('linux', () => addGenericPassword('https://scrapbox.io', 'pat', exec)),
    ).rejects.toThrow(KeychainUnavailableError)
    expect(called).toBe(false)
  })

  test('deleteGenericPassword throws KeychainUnavailableError without invoking exec', async () => {
    let called = false
    const exec: ExecFileFn = async () => {
      called = true
      return { stdout: '', stderr: '' }
    }
    await expect(
      withPlatform('linux', () => deleteGenericPassword('https://scrapbox.io', exec)),
    ).rejects.toThrow(KeychainUnavailableError)
    expect(called).toBe(false)
  })
})
