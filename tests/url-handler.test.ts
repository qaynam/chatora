// bin/chatora-open receives every link the reader clicks once the handler is installed, so
// what it decides matters more than what it does: a Cosense page goes to the running
// chatora, and everything else — including its own failures — has to reach the browser.
//
// nvim, tmux and open are stubbed to record their argv, and the Neovim sockets it looks for
// are real unix sockets in a temporary TMPDIR.
import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const HANDLER = join(import.meta.dir, '..', 'bin', 'chatora-open')
const COSENSE = 'https://scrapbox.io/my-project/ページ'

let root: string
let calls: string
let sockets: { stop: () => void }[] = []

/** A stub that appends `<name> <args...>` to the call log and answers `stdout`. */
const stub = (name: string, stdout = '') => {
  const path = join(root, 'bin', name)
  writeFileSync(
    path,
    `#!/bin/sh\nprintf '%s' "${name}" >> "$CALLS"\nfor a in "$@"; do printf ' %s' "$a" >> "$CALLS"; done\nprintf '\\n' >> "$CALLS"\n${stdout}\n`,
  )
  chmodSync(path, 0o755)
}

/** A live unix socket where Neovim would have one, so the handler's `-S` test passes. */
const nvimSocket = (name: string) => {
  const dir = join(root, 'tmp', `nvim.${process.env.USER ?? 'runner'}`, name)
  mkdirSync(dir, { recursive: true })
  const path = join(dir, 'nvim.1234.0')
  const server = Bun.listen({ unix: path, socket: { data() {} } })
  sockets.push({ stop: () => server.stop(true) })
  return path
}

const run = (url: string, env: Record<string, string> = {}) => {
  const result = Bun.spawnSync([HANDLER, url], {
    env: {
      ...process.env,
      PATH: `${join(root, 'bin')}:/usr/bin:/bin`,
      TMPDIR: join(root, 'tmp'),
      CHATORA_URL_HANDLER_DIR: join(root, 'data'),
      CALLS: calls,
      ...env,
    },
  })
  const log = readFileSync(calls, 'utf8')
  return { log, lines: log.split('\n').filter(Boolean), status: result.exitCode }
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'chatora-url-'))
  mkdirSync(join(root, 'bin'), { recursive: true })
  mkdirSync(join(root, 'data'), { recursive: true })
  mkdirSync(join(root, 'tmp'), { recursive: true })
  calls = join(root, 'calls.log')
  writeFileSync(calls, '')
  writeFileSync(join(root, 'data', 'fallback'), 'com.example.Browser\n')
  writeFileSync(join(root, 'data', 'origins'), 'scrapbox.io\n')
  writeFileSync(
    join(root, 'data', 'env'),
    `NVIM=${join(root, 'bin', 'nvim')}\nTMUX_BIN=${join(root, 'bin', 'tmux')}\n`,
  )
  stub('open')
  stub('tmux')
})

afterEach(() => {
  for (const socket of sockets) socket.stop()
  sockets = []
  rmSync(root, { recursive: true, force: true })
})

describe('chatora-open', () => {
  test('a link that is not Cosense goes to the browser, and Neovim is never asked', () => {
    stub('nvim')
    const { lines } = run('https://example.com/page')
    expect(lines).toEqual(['open -b com.example.Browser https://example.com/page'])
  })

  test('a Cosense page goes to the Neovim that has chatora', () => {
    nvimSocket('a')
    // `exists(":Chatora")` is 2 for a command, and the handler asks for nothing else here.
    stub('nvim', 'case "$*" in *Chatora*) echo 2 ;; *) echo "" ;; esac')
    const { log } = run(COSENSE)
    expect(log).toContain(`--remote-send <C-\\><C-N>:Chatora open ${COSENSE}<CR>`)
    expect(log).not.toContain('open -b')
  })

  test('a Neovim without chatora is skipped, and the browser gets it', () => {
    nvimSocket('a')
    stub('nvim', 'echo 0')
    const { log } = run(COSENSE)
    expect(log).not.toContain('--remote-send')
    expect(log).toContain(`open -b com.example.Browser ${COSENSE}`)
  })

  test('with no Neovim running at all it is still the browser, not nothing', () => {
    stub('nvim')
    const { log } = run(COSENSE)
    expect(log).toContain(`open -b com.example.Browser ${COSENSE}`)
  })

  test('the tmux pane and the terminal are brought forward, when Neovim names them', () => {
    nvimSocket('a')
    stub(
      'nvim',
      `case "$*" in
         *TMUX_PANE*) echo '%7' ;;
         *TERM_PROGRAM*) echo Ghostty ;;
         *Chatora*) echo 2 ;;
       esac`,
    )
    const { log } = run(COSENSE)
    expect(log).toContain('tmux select-window -t %7')
    expect(log).toContain('open -a Ghostty')
  })

  test('an origin the reader added is matched too', () => {
    writeFileSync(join(root, 'data', 'origins'), 'scrapbox.io\ncosense.example.com\n')
    nvimSocket('a')
    stub('nvim', 'case "$*" in *Chatora*) echo 2 ;; esac')
    const { log } = run('https://cosense.example.com/team/ページ')
    expect(log).toContain('--remote-send')
  })

  test('no URL at all does nothing', () => {
    stub('nvim')
    const { log, status } = run('')
    expect(status).toBe(0)
    expect(log).toBe('')
  })
})
