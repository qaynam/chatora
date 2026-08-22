-- Minimal nvim init for the chatora e2e harness.
--
-- Prepends the repo root (the plugin's runtimepath root) to rtp and sources
-- plugin/chatora.lua manually -- plugin/*.lua is normally auto-sourced at startup, but
-- since we only add the root to rtp *after* startup (via -u pointing here), it wouldn't be
-- picked up automatically. Same trick as tests/smoke.lua.
--
-- Driven by tests/e2e/run.ts as:
--   nvim --headless --clean -u tests/e2e/init.lua -c "luafile tests/e2e/scenario.lua"
-- with env COSENSE_PAT=test-pat, CHATORA_TEST_ORIGIN=http://127.0.0.1:<fake-cosense port>,
-- CHATORA_SETTINGS_PATH=<nonexistent path> set by run.ts.

local this_file = debug.getinfo(1, 'S').source:sub(2)
local e2e_dir = vim.fn.fnamemodify(this_file, ':p:h')
local repo_root = vim.fn.fnamemodify(e2e_dir, ':h:h')

vim.opt.rtp:prepend(repo_root)
dofile(repo_root .. '/plugin/chatora.lua')

local origin = os.getenv('CHATORA_TEST_ORIGIN')
if not origin or origin == '' then
  io.stderr:write('[e2e/init.lua] CHATORA_TEST_ORIGIN is not set; aborting\n')
  vim.cmd('cquit!')
  return
end

require('chatora').setup({
  origin = origin,
  project = 'testproj',
  server_cmd = { 'node', repo_root .. '/packages/server/dist/main.js', '--stdio' },
})
