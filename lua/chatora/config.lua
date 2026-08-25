-- Plugin configuration: user-facing defaults (see setup()), plus resolution
-- of the plugin/repo root and the chatora LSP server command to launch.
local M = {}

-- Every option's shape is documented in README.md; only defaults live here.
local defaults = {
  origin = 'https://scrapbox.io',
  project = nil,
  server_cmd = nil,

  sidebar_width = 32,
  sidebar_tabs = {
    { label = 'すべて' },
    { label = '未読', filter = 'me', unread_only = true },
  },
  sidebar_separator = true,
  sidebar_poll = 60,

  related_height = 8,
  related_auto_open = true,

  status = true,
  autosave = false,
  -- Background merge of the server's copy into the page on screen. `interval` is seconds
  -- between polls, `on_focus` also syncs the moment a page is entered, and `notify`
  -- announces what came in. `false` leaves a page exactly as opened until <leader>cf.
  sync = { interval = 30, on_focus = true, notify = true },
  completion = 'auto',
  external_link = 'confirm',
  keymaps = true,
  log = false,

  images = 'auto',
  image_backend = 'auto',
  image_height = 20,
  image_height_large = nil,
  image_gallery = true,
  image_border = true,

  pads = true,
  quote = true,
  conceal = true,
  codeblock_numbers = true,
  tables = true,
  title_margin = 1,
  spacing = { line = 0, code = 0 },

  notations = {},
}

M.options = vim.deepcopy(defaults)

local uv = vim.uv or vim.loop

local function file_exists(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == 'file'
end

-- Markers reserved by official notation ([* ], [/ ], [- ], [_ ], [$ ], [[ ]]).
local RESERVED_MARKERS = {
  ['*'] = true,
  ['/'] = true,
  ['-'] = true,
  ['_'] = true,
  ['$'] = true,
  ['['] = true,
}

-- Drops malformed entries (with a vim.notify warning) rather than erroring setup(): a typo in
-- one notation shouldn't take the whole plugin down.
local function validate_notations(notations)
  local out = {}
  for marker, spec in pairs(notations or {}) do
    if type(marker) ~= 'string' or vim.fn.strchars(marker) ~= 1 then
      vim.notify(
        '[chatora] notations: marker must be exactly one character, ignoring ' .. vim.inspect(marker),
        vim.log.levels.WARN
      )
    elseif RESERVED_MARKERS[marker] then
      vim.notify(
        '[chatora] notations: "' .. marker .. '" conflicts with an official notation, ignoring',
        vim.log.levels.WARN
      )
    elseif type(spec) ~= 'table' or type(spec.name) ~= 'string' or not spec.name:match('^[%w_]+$') then
      vim.notify(
        '[chatora] notations: invalid name for marker "' .. marker .. '", ignoring',
        vim.log.levels.WARN
      )
    else
      -- Neovim's extmark `conceal` only ever shows one character, so a
      -- multi-character icon is dropped rather than silently truncated.
      if spec.icon ~= nil and (type(spec.icon) ~= 'string' or vim.fn.strchars(spec.icon) ~= 1) then
        vim.notify(
          '[chatora] notations: icon for marker "' .. marker .. '" must be exactly one character, ignoring',
          vim.log.levels.WARN
        )
        spec.icon = nil
      end
      out[marker] = spec
    end
  end
  return out
end

-- Absolute path of the repo/plugin root, derived from this file's location:
-- lua/chatora/config.lua -> repo root. The repo root doubles as the plugin's
-- runtimepath root so plugin managers can install it straight from GitHub.
local function plugin_root()
  local source = debug.getinfo(1, 'S').source:sub(2)
  return vim.fn.fnamemodify(source, ':p:h:h:h')
end

--- The table setup() was last called with, kept unmerged so `:Chatora reload` re-applies
--- the user's configuration rather than a copy of it merged with defaults.
M.user_opts = nil

function M.setup(opts)
  M.user_opts = opts
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  M.options.notations = validate_notations(M.options.notations)
end

--- Repo root (= plugin root), used as LSP root_dir and for locating the server.
function M.get_repo_root()
  return plugin_root()
end

--- options.notations as the { marker, name } list the LSP wire format expects,
--- marker-ascending so the semantic token legend stays stable across restarts.
function M.notation_list()
  local markers = {}
  for marker in pairs(M.options.notations) do
    table.insert(markers, marker)
  end
  table.sort(markers)

  local list = {}
  for _, marker in ipairs(markers) do
    table.insert(list, { marker = marker, name = M.options.notations[marker].name })
  end
  return list
end

function M.notation_icon(name)
  local spec = M.notation_spec(name)
  return spec and spec.icon or nil
end

--- The configured spec behind a notation's semantic token `name`, or nil.
function M.notation_spec(name)
  for _, spec in pairs(M.options.notations) do
    if spec.name == name then
      return spec
    end
  end
  return nil
end

--- Highlight group carrying a notation's full-row rule (`rule = true`).
function M.notation_rule_hl(name)
  return 'ChatoraNotationRule_' .. name
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
