#!/usr/bin/env node
// Boots the built dist/main.js exactly the way nvim/lua/chatora/config.lua spawns it
// (`node dist/main.js --stdio`), with no node_modules alongside it, and drives it over
// real LSP Content-Length framing: initialize -> initialized -> chatora/authStatus ->
// shutdown -> exit. Fails loudly (nonzero exit) on any mismatch, timeout, or crash.
import { spawn } from 'node:child_process'
import { existsSync, mkdtempSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const serverPath = path.join(here, '..', 'dist', 'main.js')
const TIMEOUT_MS = 10_000

if (!existsSync(serverPath)) {
  console.error(`smoke: ${serverPath} does not exist — run \`bun run build\` first`)
  process.exit(1)
}

// Run from a scratch directory with no node_modules anywhere above it (not `here`, which
// sits inside packages/server/node_modules's own ancestry) — this is the real proof that
// the bundle needs zero node_modules assistance, matching how nvim spawns it standalone.
const cwd = mkdtempSync(path.join(os.tmpdir(), 'chatora-smoke-'))

// Hermetic: no env COSENSE_PAT, and CHATORA_SETTINGS_PATH points at a path that doesn't
// exist, so resolveCredential's settings.json branch cleanly finds nothing. A real macOS
// Keychain lookup may still run (findGenericPassword shells out to `security`) — it must
// soft-fail to null when the "chatora" entry is absent, which is exactly what we're
// asserting authStatus survives without hanging or crashing.
const env = { ...process.env }
delete env.COSENSE_PAT
env.CHATORA_SETTINGS_PATH = path.join(cwd, 'does-not-exist', 'settings.json')
env.COSENSE_SETTINGS_PATH = env.CHATORA_SETTINGS_PATH

const child = spawn('node', [serverPath, '--stdio'], {
  cwd,
  env,
  stdio: ['pipe', 'pipe', 'pipe'],
})

let stderr = ''
child.stderr.on('data', (chunk) => {
  stderr += chunk.toString('utf8')
})

let failed = false
const fail = (message) => {
  failed = true
  console.error(`smoke FAILED: ${message}`)
  if (stderr) console.error(`--- stderr ---\n${stderr}`)
  child.kill('SIGKILL')
  process.exitCode = 1
}

const timeout = setTimeout(() => fail(`timed out after ${TIMEOUT_MS}ms`), TIMEOUT_MS)

child.on('error', (error) => fail(`failed to spawn server: ${error.message}`))
child.on('exit', (code, signal) => {
  clearTimeout(timeout)
  if (!failed && !finished) {
    fail(`server exited early (code=${code}, signal=${signal})`)
  }
})

// --- minimal Content-Length-framed JSON-RPC client ---------------------------------

let buffer = Buffer.alloc(0)
let nextId = 1
const pending = new Map()

const send = (message) => {
  const body = Buffer.from(JSON.stringify(message), 'utf8')
  const header = Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, 'ascii')
  child.stdin.write(Buffer.concat([header, body]))
}

const request = (method, params) =>
  new Promise((resolve, reject) => {
    const id = nextId++
    pending.set(id, { resolve, reject })
    send({ jsonrpc: '2.0', id, method, params })
  })

const notify = (method, params) => send({ jsonrpc: '2.0', method, params })

child.stdout.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk])
  for (;;) {
    const headerEnd = buffer.indexOf('\r\n\r\n')
    if (headerEnd < 0) return
    const header = buffer.subarray(0, headerEnd).toString('ascii')
    const match = /Content-Length:\s*(\d+)/i.exec(header)
    if (!match) return fail(`malformed LSP header: ${JSON.stringify(header)}`)
    const length = Number(match[1])
    const bodyStart = headerEnd + 4
    if (buffer.length < bodyStart + length) return // wait for the rest
    const body = buffer.subarray(bodyStart, bodyStart + length).toString('utf8')
    buffer = buffer.subarray(bodyStart + length)

    let message
    try {
      message = JSON.parse(body)
    } catch (error) {
      return fail(`response body was not valid JSON: ${error.message}`)
    }
    if (typeof message.id !== 'undefined' && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id)
      pending.delete(message.id)
      if (message.error) reject(new Error(JSON.stringify(message.error)))
      else resolve(message.result)
    }
    // notifications from the server (e.g. window/logMessage) are ignored here
  }
})

// --- the actual scenario -------------------------------------------------------------

let finished = false

const assert = (condition, message) => {
  if (!condition) throw new Error(message)
}

const main = async () => {
  const initResult = await request('initialize', {
    processId: process.pid,
    rootUri: null,
    capabilities: {},
    initializationOptions: { origin: 'https://scrapbox.io' },
  })

  assert(initResult && typeof initResult === 'object', 'initialize returned no result')
  const capabilities = initResult.capabilities
  assert(capabilities?.semanticTokensProvider, 'missing capabilities.semanticTokensProvider')
  assert(
    Array.isArray(capabilities.semanticTokensProvider.legend?.tokenTypes),
    'semanticTokensProvider.legend.tokenTypes is not an array',
  )
  assert(capabilities?.completionProvider, 'missing capabilities.completionProvider')
  assert(capabilities?.definitionProvider, 'missing capabilities.definitionProvider')

  notify('initialized', {})

  const authResult = await request('chatora/authStatus', {})
  assert(authResult && typeof authResult === 'object', 'chatora/authStatus returned no result')
  assert(typeof authResult.ok === 'boolean', 'chatora/authStatus result missing boolean ok')
  if (authResult.ok) {
    assert(typeof authResult.authenticated === 'boolean', 'ok:true result missing authenticated')
  } else {
    assert(typeof authResult.code === 'string', 'ok:false result missing code')
  }

  await request('shutdown', null)
  notify('exit', null)

  finished = true
  clearTimeout(timeout)
  console.log('smoke OK: initialize capabilities + chatora/authStatus both well-formed')

  setTimeout(() => {
    if (!child.killed) child.kill('SIGKILL')
    process.exit(0)
  }, 500).unref()
}

main().catch((error) => fail(error.message))
