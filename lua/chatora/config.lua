-- Plugin configuration: user-facing defaults (see setup()), plus resolution
-- of the plugin/repo root and the chatora LSP server command to launch.
local M = {}

local defaults = {
  origin = 'https://scrapbox.io',
  project = nil,
  server_cmd = nil,
  sidebar_width = 32,
  -- neo-tree-style sources shown as tabs in the sidebar's winbar. Each entry is
  -- { label, filter?, unread_only? }, where filter is 'me' (the signed-in
  -- user's first saved Cosense page filter, falling back to an icon filter on
  -- their own name) or an explicit { type = 'icon', value = 'name' }.
  -- false collapses the sidebar to a single unfiltered list.
  sidebar_tabs = {
    { label = 'すべて' },
    { label = '未読', filter = 'me', unread_only = true },
  },
  related_height = 8,
  -- Open the related-pages panel automatically when a page is opened. Closing
  -- it with q suppresses reopening until the next gR / :Chatora related.
  related_auto_open = true,
  -- Save-state indicator: a small icon (sidebar mark / statusline component /
  -- one cmdline echo) instead of toast notifications. false disables; a table
  -- customizes: { icons = { clean='✓', dirty='●', saving='◍', error='✗' },
  -- echo = false }.
  status = true,
  -- gd on an external URL: 'confirm' asks before opening in the browser,
  -- 'open' opens immediately, 'ignore' leaves external links alone.
  external_link = 'confirm',
  -- Cosense's editor shortcuts in page buffers (insert mode). false disables
  -- all; a table customizes/disables individually:
  -- { insert_date = '<C-t>', insert_icon = '<C-i>',
  --   date_format = '%Y-%m-%d %H:%M:%S', autopair = true }.
  -- NOTE: <C-i> is <Tab> unless the terminal speaks the kitty keyboard
  -- protocol (kitty / Ghostty / WezTerm).
  keymaps = true,
  -- Blank virtual lines inserted between lines: { line = 0, code = 0 }
  -- (body lines / code-block interiors). A terminal cell has a fixed height,
  -- so real (sub-cell) line-height only exists in GUIs ('linespace').
  spacing = { line = 0, code = 0 },
  -- 'auto' = render inline images when a backend is usable; false = never.
  images = 'auto',
  -- Render backend: 'auto' prefers 3rd/image.nvim, falling back to
  -- folke/snacks.nvim's image module. 'image_nvim' / 'snacks' force one.
  image_backend = 'auto',
  -- Frame composited into standalone images themselves (ImageMagick,
  -- server-side): a transparent padding ring + a border line, so an image
  -- reads as embedded content instead of blending into the page. false
  -- disables; a table customizes: { width = 1, color = '#8888', padding = 12 }
  -- (pixels; color is any ImageMagick color literal, #rgba works).
  image_border = true,
  -- Completion UI in page buffers: 'auto' enables Neovim's native LSP
  -- completion (autotrigger) when blink.cmp is absent or disabled for the
  -- buffer; 'native' always enables it; false leaves completion entirely to
  -- an external engine.
  completion = 'auto',
  -- Seconds of idle time after an edit before the page is saved automatically;
  -- false disables autosave.
  autosave = false,
  -- Cosense-style bullet pads on indented lines (guides + a bullet at the
  -- deepest level, plus inline spacing so it reads as a list). false disables;
  -- a table overrides any of { bullet = '●', guide = '┃', spacing = true,
  -- gap = 0 } — gap being the spaces between the bullet and its text.
  pads = true,
  -- Conceal notation markup ([* ], link brackets, backticks) except on the
  -- cursor line (render-markdown.nvim style). false disables.
  conceal = true,
  tables = true,
  -- Blank virtual lines shown below the page title. 0 disables.
  title_margin = 1,
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
