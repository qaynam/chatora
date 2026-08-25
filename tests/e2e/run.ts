#!/usr/bin/env bun
// E2E harness orchestrator for chatora.
//
//   bun tests/e2e/run.ts        (run from the repo root)
//
// Validates the full chain -- Neovim Lua plugin -> chatora LSP server (node) -> HTTP --
// against a fake, in-process Cosense API server (tests/e2e/fake-cosense.ts). No real
// credentials, no network access, no macOS Keychain calls (COSENSE_PAT is set below, which
// resolveCredential() checks before ever shelling out to `security`).
//
// Steps:
//   1. Ensure packages/server/dist/main.js exists (builds it via the workspace filter if not).
//   2. Start the fake Cosense server in-process on an ephemeral port.
//   3. Spawn `nvim --headless --clean -u tests/e2e/init.lua -c "luafile tests/e2e/scenario.lua"`,
//      which drives the real plugin -> LSP server -> HTTP chain (see scenario.lua for the
//      step-by-step script) and exits 0/nonzero via :qa!/:cquit!.
//   4. Once nvim exits cleanly, fetch the fake server's request log (`GET /__test/requests`)
//      and assert on the HTTP traffic the server actually produced.
//   5. Print `E2E OK` and exit 0 only if nvim's scenario succeeded AND every traffic
//      assertion passed.

import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { type RequestLogEntry, startFakeCosense } from './fake-cosense'

const E2E_DIR = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(E2E_DIR, '..', '..')
const SERVER_DIST = join(REPO_ROOT, 'packages', 'server', 'dist', 'main.js')
const INIT_LUA = join(E2E_DIR, 'init.lua')
const SCENARIO_LUA = join(E2E_DIR, 'scenario.lua')

const NVIM_TIMEOUT_MS = 120_000

const log = (msg: string): void => console.log(`[run.ts] ${msg}`)

// -----------------------------------------------------------------------------------------
// 1. Ensure the server bundle exists
// -----------------------------------------------------------------------------------------

const ensureServerBuilt = async (): Promise<void> => {
  if (existsSync(SERVER_DIST)) {
    log(`server bundle found: ${SERVER_DIST}`)
    return
  }
  log(`${SERVER_DIST} missing; building (bun run --filter '@chatora/server' build)...`)
  const build = Bun.spawn({
    cmd: ['bun', 'run', '--filter', '@chatora/server', 'build'],
    cwd: REPO_ROOT,
    stdout: 'inherit',
    stderr: 'inherit',
  })
  const code = await build.exited
  if (code !== 0) {
    console.error(`[run.ts] build failed with exit code ${code}`)
    process.exit(1)
  }
  if (!existsSync(SERVER_DIST)) {
    console.error(`[run.ts] build succeeded but ${SERVER_DIST} still does not exist`)
    process.exit(1)
  }
  log('build OK')
}

// -----------------------------------------------------------------------------------------
// 2. Start the fake Cosense server
// -----------------------------------------------------------------------------------------

await ensureServerBuilt()

const fake = startFakeCosense()
log(`fake-cosense listening on ${fake.origin}`)

// -----------------------------------------------------------------------------------------
// 3. Spawn nvim headless and drive the scenario
// -----------------------------------------------------------------------------------------

const readStream = async (stream: ReadableStream<Uint8Array> | null): Promise<string> => {
  if (!stream) return ''
  const reader = stream.getReader()
  const chunks: Uint8Array[] = []
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    if (value) chunks.push(value)
  }
  return Buffer.concat(chunks).toString('utf8')
}

const runScenario = async (): Promise<{
  exitCode: number
  stdout: string
  stderr: string
  timedOut: boolean
}> => {
  const env: Record<string, string> = {
    ...(process.env as Record<string, string>),
    COSENSE_PAT: 'test-pat',
    CHATORA_TEST_ORIGIN: fake.origin,
    COSENSE_SETTINGS_PATH: '/nonexistent/chatora-e2e-settings.json',
  }

  const proc = Bun.spawn({
    cmd: ['nvim', '--headless', '--clean', '-u', INIT_LUA, '-c', `luafile ${SCENARIO_LUA}`],
    cwd: REPO_ROOT,
    env,
    stdout: 'pipe',
    stderr: 'pipe',
  })

  const stdoutPromise = readStream(proc.stdout as ReadableStream<Uint8Array> | null)
  const stderrPromise = readStream(proc.stderr as ReadableStream<Uint8Array> | null)

  let timedOut = false
  const timer = setTimeout(() => {
    timedOut = true
    proc.kill('SIGKILL')
  }, NVIM_TIMEOUT_MS)

  const exitCode = await proc.exited
  clearTimeout(timer)

  const [stdout, stderr] = await Promise.all([stdoutPromise, stderrPromise])
  return { exitCode, stdout, stderr, timedOut }
}

log('spawning nvim --headless with tests/e2e/{init,scenario}.lua ...')
const { exitCode, stdout, stderr, timedOut } = await runScenario()

console.log('----- nvim stdout -----')
console.log(stdout.trimEnd() || '(empty)')
console.log('----- nvim stderr -----')
console.log(stderr.trimEnd() || '(empty)')
console.log('------------------------')

if (timedOut) {
  console.error(`[run.ts] nvim scenario timed out after ${NVIM_TIMEOUT_MS}ms and was killed`)
  fake.stop()
  process.exit(1)
}
if (exitCode !== 0) {
  console.error(`[run.ts] nvim scenario exited with code ${exitCode} (expected 0)`)
  fake.stop()
  process.exit(1)
}
// nvim --headless's Lua print() typically lands on stderr, not stdout -- check both.
if (!stdout.includes('SCENARIO OK') && !stderr.includes('SCENARIO OK')) {
  console.error(
    '[run.ts] nvim exited 0 but never printed SCENARIO OK (stdout or stderr) -- treating as a failure',
  )
  fake.stop()
  process.exit(1)
}
log('nvim scenario passed (SCENARIO OK, exit 0)')

// -----------------------------------------------------------------------------------------
// 4. Fetch the fake server's request log and assert on the HTTP traffic
// -----------------------------------------------------------------------------------------

const requestsRes = await fetch(`${fake.origin}/__test/requests`)
const requests = (await requestsRes.json()) as RequestLogEntry[]

const HOME_TITLE = 'ホーム'
const V2_PREFIX = '/api/pages/v2/testproj/'
const PREVIEW_PATH = '/api/pages/v2/testproj/page-edit-for-ai/preview'
const SUBMIT_PATH = '/api/pages/v2/testproj/page-edit-for-ai/submit'
const LINE_ID_RE = /^[0-9a-f]{24}$/

/** Title encoded in a /api/pages/v2/testproj/<title>[/links1hop|/links2hop] GET path. */
const v2Title = (path: string): { title: string; hop: 'links1hop' | 'links2hop' | null } | null => {
  if (!path.startsWith(V2_PREFIX)) return null
  if (path === PREVIEW_PATH || path === SUBMIT_PATH) return null
  let rest = path.slice(V2_PREFIX.length)
  let hop: 'links1hop' | 'links2hop' | null = null
  if (rest.endsWith('/links1hop')) {
    hop = 'links1hop'
    rest = rest.slice(0, -'/links1hop'.length)
  } else if (rest.endsWith('/links2hop')) {
    hop = 'links2hop'
    rest = rest.slice(0, -'/links2hop'.length)
  }
  try {
    return { title: decodeURIComponent(rest), hop }
  } catch {
    return { title: rest, hop }
  }
}

const failures: string[] = []
const okList: string[] = []

const check = (label: string, condition: boolean, detail?: unknown): void => {
  if (condition) {
    okList.push(label)
  } else {
    failures.push(`${label}${detail !== undefined ? ` -- ${JSON.stringify(detail)}` : ''}`)
  }
}

// (a) exactly one successful GET /api/users/me
const meRequests = requests.filter((r) => r.method === 'GET' && r.path === '/api/users/me')
check(
  'exactly one GET /api/users/me, status 200',
  meRequests.length === 1 && meRequests[0]?.status === 200,
  meRequests,
)

// (b) GET page ホーム happened (v2 path, encoded)
const homeGets = requests.filter((r) => {
  if (r.method !== 'GET') return false
  const parsed = v2Title(r.path)
  return parsed !== null && parsed.hop === null && parsed.title === HOME_TITLE
})
check('GET /api/pages/v2/testproj/<encoded ホーム> happened', homeGets.length >= 1, {
  count: homeGets.length,
})

// (c) links1hop + links2hop both requested (for ホーム)
const links1hopReq = requests.find((r) => {
  if (r.method !== 'GET') return false
  const parsed = v2Title(r.path)
  return parsed !== null && parsed.hop === 'links1hop' && parsed.title === HOME_TITLE
})
const links2hopReq = requests.find((r) => {
  if (r.method !== 'GET') return false
  const parsed = v2Title(r.path)
  return parsed !== null && parsed.hop === 'links2hop' && parsed.title === HOME_TITLE
})
check('GET .../ホーム/links1hop happened', links1hopReq !== undefined)
check('GET .../ホーム/links2hop happened', links2hopReq !== undefined)

// (d) preview POST shape
const previewRequests = requests.filter((r) => r.method === 'POST' && r.path === PREVIEW_PATH)
check(
  'exactly one POST .../page-edit-for-ai/preview',
  previewRequests.length === 1,
  previewRequests,
)

const previewReq = previewRequests[0]
if (previewReq) {
  const body = previewReq.body as { pageId?: string; changes?: unknown[] } | undefined
  check('preview body.pageId === "pg1"', body?.pageId === 'pg1', body)

  const changes = body?.changes
  const change =
    Array.isArray(changes) && changes.length === 1
      ? (changes[0] as Record<string, unknown>)
      : undefined
  check(
    'preview body.changes has exactly one change',
    Array.isArray(changes) && changes.length === 1,
    changes,
  )
  if (change) {
    check('change._insert === "_end"', change._insert === '_end', change)
    const lines = change.lines as { id?: unknown; text?: unknown } | undefined
    check(
      'change.lines.id is 24 lowercase hex chars',
      typeof lines?.id === 'string' && LINE_ID_RE.test(lines.id),
      lines?.id,
    )
    check('change.lines.text === "あたらしい行"', lines?.text === 'あたらしい行', lines?.text)
  }
}

// (e) submit POST carries previewId 'pv1'
const submitRequests = requests.filter((r) => r.method === 'POST' && r.path === SUBMIT_PATH)
check('exactly one POST .../page-edit-for-ai/submit', submitRequests.length === 1, submitRequests)
const submitReq = submitRequests[0]
if (submitReq) {
  const body = submitReq.body as { previewId?: string } | undefined
  check('submit body.previewId === "pv1"', body?.previewId === 'pv1', body)
}

// (f) a refetch GET of ホーム happened AFTER submit
const submitIndex = submitReq ? requests.indexOf(submitReq) : -1
const refetchAfterSubmit = homeGets.some((r) => requests.indexOf(r) > submitIndex)
check(
  'a GET of ホーム happened after the submit POST (post-submit refetch)',
  submitIndex >= 0 && refetchAfterSubmit,
  {
    submitIndex,
    homeGetIndices: homeGets.map((r) => requests.indexOf(r)),
  },
)

// opening a page records the read, which is the only thing that clears its unread mark
const accessedPosts = requests.filter(
  (r) => r.method === 'POST' && /\/api\/pages\/[^/]+\/[^/]+\/accessed$/.test(r.path),
)
check(
  'opening a page POSTs to .../accessed',
  accessedPosts.length >= 1,
  accessedPosts.map((r) => `${r.method} ${r.path} -> ${r.status}`),
)

// The scenario opens exactly two pages (ホーム, then メモ from the picker). The picker also
// *previews* メモ, and scrolling a picker past a page must never count as reading it.
check(
  'previewing a page in the picker does not POST .../accessed',
  accessedPosts.length === 2,
  accessedPosts.map((r) => `${r.method} ${r.path} -> ${r.status}`),
)

// Reopening the sidebar serves the cached list. The scenario opens it, closes it and opens
// it again; a refetch would show up as a second paged listing. `skip=` is what tells the
// sidebar's batches apart from the picker's flat recent-pages query against the same path.
const sidebarListRequests = requests.filter(
  (r) => r.method === 'GET' && /^\/api\/pages\/[^/]+\/$/.test(r.path) && r.query.includes('skip='),
)
check(
  'reopening the sidebar does not refetch the page list',
  sidebarListRequests.length === 1,
  sidebarListRequests.map((r) => `${r.method} ${r.path}${r.query} -> ${r.status}`),
)

// (g) no request ever carried a wrong/absent token -- zero 401s anywhere in the log
const unauthorized = requests.filter((r) => r.status === 401)
check('zero 401 responses across the whole request log', unauthorized.length === 0, unauthorized)

// -----------------------------------------------------------------------------------------
// 5. Report
// -----------------------------------------------------------------------------------------

console.log('----- traffic assertions -----')
for (const label of okList) console.log(`  OK   ${label}`)
for (const label of failures) console.log(`  FAIL ${label}`)
console.log(`------------------------------- (${okList.length} ok, ${failures.length} failed)`)

fake.stop()

if (failures.length > 0) {
  console.error(`[run.ts] ${failures.length} traffic assertion(s) failed`)
  process.exit(1)
}

console.log('E2E OK')
process.exit(0)
