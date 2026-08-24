import { chmod, mkdir, readFile, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { Context, Effect, Layer, Option } from 'effect'
import { CommandExecutor } from './commandExecutor'
import { KeychainError } from './errors'
import { addGenericPassword, deleteGenericPassword, findGenericPassword } from './keychain'

export interface Account {
  readonly id: string
  readonly origin: string
  readonly userId: string
  readonly name: string
  readonly displayName: string
  readonly photo?: string
}

interface AccountIndex {
  readonly active: string | null
  readonly accounts: readonly Account[]
}

const EMPTY_INDEX: AccountIndex = { active: null, accounts: [] }

const isAccount = (value: unknown): value is Account => {
  if (typeof value !== 'object' || value === null) return false
  const v = value as Record<string, unknown>
  return (
    typeof v.id === 'string' &&
    typeof v.origin === 'string' &&
    typeof v.userId === 'string' &&
    typeof v.name === 'string' &&
    typeof v.displayName === 'string' &&
    (v.photo === undefined || typeof v.photo === 'string')
  )
}

// Nothing outside chatora writes this file, so a missing or corrupt one means "no accounts
// yet", not an error worth surfacing.
const parseIndex = (text: string): AccountIndex => {
  try {
    const parsed: unknown = JSON.parse(text)
    if (typeof parsed !== 'object' || parsed === null) return EMPTY_INDEX
    const raw = parsed as { active?: unknown; accounts?: unknown }
    return {
      active: typeof raw.active === 'string' ? raw.active : null,
      accounts: Array.isArray(raw.accounts) ? raw.accounts.filter(isAccount) : [],
    }
  } catch {
    return EMPTY_INDEX
  }
}

/**
 * `${CHATORA_STATE_DIR}/accounts.json` when that env var is set (the test override point),
 * otherwise `${XDG_STATE_HOME:-$HOME/.local/state}/chatora/accounts.json`. Resolved fresh on
 * every call rather than once per process/layer, so tests can repoint it per case.
 */
const indexPath = (): string => {
  const override = process.env.CHATORA_STATE_DIR
  if (override !== undefined && override !== '') return join(override, 'accounts.json')
  const xdgStateHome = process.env.XDG_STATE_HOME
  const stateHome =
    xdgStateHome !== undefined && xdgStateHome !== ''
      ? xdgStateHome
      : join(homedir(), '.local', 'state')
  return join(stateHome, 'chatora', 'accounts.json')
}

const readIndex = (filePath: string): Effect.Effect<AccountIndex> =>
  Effect.tryPromise(() => readFile(filePath, 'utf8')).pipe(
    Effect.map(parseIndex),
    Effect.catchAll(() => Effect.succeed(EMPTY_INDEX)),
  )

// The index never holds a PAT (that's Keychain-only), but it's still account metadata —
// written 0600 to match the privacy of the Keychain entries it points at.
const writeIndex = (filePath: string, index: AccountIndex): Effect.Effect<void, KeychainError> =>
  Effect.tryPromise({
    try: async () => {
      await mkdir(dirname(filePath), { recursive: true })
      await writeFile(filePath, JSON.stringify(index, null, 2))
      await chmod(filePath, 0o600)
    },
    catch: (cause) =>
      new KeychainError({ message: `Failed to write chatora account index at ${filePath}`, cause }),
  })

export interface AccountStoreShape {
  readonly list: () => Effect.Effect<{
    readonly active: Option.Option<string>
    readonly accounts: readonly Account[]
  }>
  /** Stores `pat` in Keychain under `account.id`, upserts `account` into the index, and makes it active. */
  readonly add: (account: Account, pat: string) => Effect.Effect<void, KeychainError>
  /**
   * Deletes the Keychain entry and the index row for `id`. If `id` was active, the first
   * remaining account (if any) becomes active; with no accounts left, active is cleared.
   */
  readonly remove: (id: string) => Effect.Effect<void, KeychainError>
  /** `Option.none` — and the index left untouched — when `id` isn't in the index. */
  readonly setActive: (id: string) => Effect.Effect<Option.Option<Account>>
  /** The active account's PAT, or `Option.none` when there's no active account or it's for a different origin. */
  readonly resolveActive: (origin: string) => Effect.Effect<Option.Option<string>>
}

export class AccountStore extends Context.Tag('@chatora/core/AccountStore')<
  AccountStore,
  AccountStoreShape
>() {}

export const AccountStoreLive: Layer.Layer<AccountStore, never, CommandExecutor> = Layer.effect(
  AccountStore,
  Effect.gen(function* () {
    const executor = yield* CommandExecutor

    const list: AccountStoreShape['list'] = () =>
      Effect.map(readIndex(indexPath()), (index) => ({
        active: Option.fromNullable(index.active),
        accounts: index.accounts,
      }))

    const add: AccountStoreShape['add'] = (account, pat) =>
      Effect.gen(function* () {
        yield* addGenericPassword(account.id, pat, executor)
        const filePath = indexPath()
        const index = yield* readIndex(filePath)
        const accounts = [...index.accounts.filter((a) => a.id !== account.id), account]
        yield* writeIndex(filePath, { active: account.id, accounts })
      })

    const remove: AccountStoreShape['remove'] = (id) =>
      Effect.gen(function* () {
        // Best-effort: a missing Keychain item (deleted by hand, non-darwin)
        // must not leave the account stuck in the index.
        yield* deleteGenericPassword(id, executor).pipe(Effect.catchAll(() => Effect.void))
        const filePath = indexPath()
        const index = yield* readIndex(filePath)
        const accounts = index.accounts.filter((a) => a.id !== id)
        const active = index.active === id ? (accounts[0]?.id ?? null) : index.active
        yield* writeIndex(filePath, { active, accounts })
      })

    const setActive: AccountStoreShape['setActive'] = (id) =>
      Effect.gen(function* () {
        const filePath = indexPath()
        const index = yield* readIndex(filePath)
        const account = index.accounts.find((a) => a.id === id)
        if (account === undefined) return Option.none<Account>()
        yield* writeIndex(filePath, { active: id, accounts: index.accounts }).pipe(Effect.orDie)
        return Option.some(account)
      })

    const resolveActive: AccountStoreShape['resolveActive'] = (origin) =>
      Effect.gen(function* () {
        const index = yield* readIndex(indexPath())
        if (index.active === null) return Option.none<string>()
        const account = index.accounts.find((a) => a.id === index.active)
        if (account === undefined || account.origin !== origin) return Option.none<string>()
        return yield* findGenericPassword(account.id, executor)
      })

    return AccountStore.of({ list, add, remove, setActive, resolveActive })
  }),
)
