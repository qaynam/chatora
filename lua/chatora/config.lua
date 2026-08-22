local M = {}

local defaults = {
  origin = 'https://scrapbox.io',
  project = nil,
  server_cmd = nil,
  sidebar_width = 32,
  related_height = 8,
  -- 'auto' = render inline images when snacks.nvim's image module is
  -- installed and the terminal supports it; false = never.
  images = 'auto',
  -- Seconds of idle time after an edit before the page is saved automatically;
  -- false disables autosave.
  autosave = false,
  -- Cosense-style bullet pads on indented lines (guides + a bullet at the
  -- deepest level, plus inline spacing so it reads as a list). false disables;
  -- a table customizes: { bullet = '⬤', guide = '│', spacing = true }.
  pads = true,
  -- Conceal notation markup ([* ], link brackets, backticks) except on the
  -- cursor line (render-markdown.nvim style). false disables.
  conceal = true,
}

M.options = vim.deepcopy(defaults)

local uv = vim.uv or vim.loop

local function file_exists(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == 'file'
end

-- Absolute path of the repo/plugin root, derived from this file's location:
-- lua/chatora/config.lua -> repo root. The repo root doubles as the plugin's
-- runtimepath root so plugin managers can install it straight from GitHub.
local function plugin_root()
  local source = debug.getinfo(1, 'S').source:sub(2)
  return vim.fn.fnamemodify(source, ':p:h:h:h')
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
end

--- Repo root (= plugin root), used as LSP root_dir and for locating the server.
function M.get_repo_root()
  return plugin_root()
end

--- Resolve the server command to launch.
--- Priority: explicit opts.server_cmd -> built dist/main.js (node) ->
--- source src/main.ts (bun, dev fallback) -> nil.
function M.get_server_cmd()
  if M.options.server_cmd then
    return M.options.server_cmd
  end

  local repo_root = M.get_repo_root()
  local main_js = repo_root .. '/packages/server/dist/main.js'
  if file_exists(main_js) then
    return { 'node', main_js, '--stdio' }
  end

  local main_ts = repo_root .. '/packages/server/src/main.ts'
  if file_exists(main_ts) then
    return { 'bun', 'run', main_ts, '--stdio' }
  end

  return nil
end

return M
