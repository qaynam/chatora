local M = {}

local defaults = {
  origin = 'https://scrapbox.io',
  project = nil,
  server_cmd = nil,
  sidebar_width = 32,
  related_height = 8,
}

M.options = vim.deepcopy(defaults)

local uv = vim.uv or vim.loop

local function file_exists(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == 'file'
end

-- Absolute path of the nvim/ plugin root, derived from this file's location:
-- nvim/lua/chatora/config.lua -> nvim/
local function plugin_root()
  local source = debug.getinfo(1, 'S').source:sub(2)
  return vim.fn.fnamemodify(source, ':p:h:h:h')
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
end

--- Repo root: the parent directory of nvim/, used as LSP root_dir.
function M.get_repo_root()
  return vim.fn.fnamemodify(plugin_root(), ':h')
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
