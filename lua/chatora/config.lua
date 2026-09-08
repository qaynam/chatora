-- Plugin configuration: user-facing defaults (see setup()), plus resolution
-- of the plugin/repo root and the chatora LSP server command to launch.
local M = {}

---@class chatora.SetupContext
---@field project? string  The project being entered; nil for the call made at startup.

---@class chatora.SourceContext
---@field project string
---@field log fun(...)  Shown in :messages and written to the server log; safe off the main loop.
---@field done fun(result?: table, why?: string)  Hands the result in later; `done(nil, why)` reports a failure.

---@class chatora.Row
---@field title string
---@field image? string  URL, or a path on this machine.
---@field action? fun(row: chatora.Row, win: integer)  Called on <CR> instead of opening a page.

--- A tab, or a folder inside one. One of filter / mine / related / pages / folders decides
--- what it holds; none means every page of the project.
---@class chatora.TabSpec
---@field name string
---@field icon? string
---@field image? string
---@field filter? string|{ type: string, value: string }  A page title: the web's icon filter.
---@field mine? boolean  The reader's own pages (the saved web filter when there is one).
---@field related? string|string[]  Pages linked to these, merged into one list.
---@field pages? (chatora.Row|string)[]|fun(ctx: chatora.SourceContext): (chatora.Row|string)[]?
---@field unread? boolean
---@field open? boolean  Folders only: whether it starts open.
---@field folders? chatora.TabSpec[]|fun(ctx: chatora.SourceContext): chatora.TabSpec[]?

---@class chatora.SidebarConfig
---@field width? integer
---@field separator? boolean|string  A row underline; a color string sets its color.
---@field thumbnails? boolean  A page's first picture in front of its title (needs an image backend).
---@field refresh_interval? integer|false  Seconds between refreshes of the list on screen.
---@field tabs? chatora.TabSpec[]|false  `false` for a single list without tabs.

---@class chatora.RelatedConfig
---@field position? 'bottom'|'right'
---@field height? integer  When position is 'bottom'.
---@field width? integer  When position is 'right'.
---@field auto_open? boolean

---@class chatora.SyncConfig
---@field interval? integer  Seconds between polls.
---@field on_focus? boolean  Also sync the moment a page is entered.
---@field notify? boolean  Announce what came in.

---@class chatora.EditConfig
---@field autosave? integer|false  Seconds after the last edit.
---@field sync? chatora.SyncConfig|false  Background merge of the server's copy into the page.
---@field save_status? boolean|{ icons?: table<string, string>, echo?: boolean }
---@field completion? 'auto'|'native'|false  'auto' enables the built-in completion only without an external engine.
---@field autopair? boolean  Typing `[` inserts `[]`.
---@field table_tab? boolean  <Tab> inserts a real tab on a table row.
---@field surround? boolean|string[]  Visual-mode decoration keys; a list of markers restricts them.
---@field paste_indent? boolean  `p` / `P` give pasted lines the indent of the line they land on.
---@field date_format? string  os.date format of what insert_date inserts.

---@class chatora.TelomereConfig
---@field bar? boolean  The per-line mark in the sign column.
---@field scrollbar? boolean  The overview of the whole page down the right edge.

---@class chatora.QuoteConfig
---@field bar? string  The glyph standing in for `>`.
---@field hl? vim.api.keyset.highlight  For the bar (ChatoraQuoteBar).
---@field text_hl? vim.api.keyset.highlight|false  For the quoted text (ChatoraQuoteText).
---@field dim? boolean  Dim the text instead of tinting its background.
---@field wrap? boolean  Continue the bar on wrapped lines.

---@class chatora.ViewConfig
---@field conceal? boolean|string  `true` reveals markup on the cursor line; a string is used as 'concealcursor'.
---@field pads? boolean|{ bullet?: string }  The bullet of a list item.
---@field quote? boolean|chatora.QuoteConfig
---@field telomere? chatora.TelomereConfig|false
---@field tables? boolean|{ border?: boolean, header?: boolean }
---@field codeblock_numbers? boolean
---@field file_icon? string|false  Drawn in place of the opening bracket of a link to an uploaded file.
---@field title_margin? integer  Virtual blank lines under the title.
---@field spacing? { line?: integer, code?: integer }  Virtual blank lines between lines.

---@class chatora.ImageConfig
---@field enabled? boolean
---@field backend? 'auto'|'image_nvim'|'snacks'|table|fun(): table  'auto' prefers image.nvim, then snacks.nvim.
---@field height? integer  Rows for a picture on a line of its own.
---@field height_large? integer  Rows for the `[[…]]` notation; defaults to twice `height`.
---@field gallery? boolean|integer|{ rows?: integer, aspect?: number }  Tiles for a line of pictures only.
---@field border? boolean|{ width?: integer, color?: string, padding?: integer }

--- Keys as `vim.keymap.set` takes them; a list maps several, `false` maps none. Defaults
--- under `prefix` are written `<prefix>x`. Everything but the first six is mapped in page
--- buffers only.
---@class chatora.Keymaps
---@field prefix? string|false  The namespace of the `<prefix>x` defaults; `false` drops all of them.
---@field sidebar? string|string[]|false
---@field search? string|string[]|false
---@field new? string|string[]|false
---@field project? string|string[]|false
---@field account? string|string[]|false
---@field help? string|string[]|false
---@field follow? string|string[]|false
---@field related? string|string[]|false
---@field related_side? string|string[]|false
---@field info? string|string[]|false
---@field pull? string|string[]|false
---@field next_conflict? string|string[]|false
---@field next_updated? string|string[]|false
---@field prev_updated? string|string[]|false
---@field paste_image? string|string[]|false
---@field delete? string|string[]|false
---@field normalize_indent? string|string[]|false
---@field copy_url? string|string[]|false
---@field copy_link? string|string[]|false
---@field open_in_browser? string|string[]|false
---@field insert_date? string|string[]|false
---@field insert_icon? string|string[]|false

---@class chatora.NotationSpec
---@field name string  Identifier of the semantic token; letters, digits and `_`.
---@field icon? string  One character drawn in place of the marker.
---@field hl? vim.api.keyset.highlight
---@field rule? boolean  Extend the highlight across the whole row.

---@class chatora.Config
---@field origin? string
---@field default_project? string  Opened without asking; `:Chatora project` overrides it for the session.
---@field server_cmd? string[]
---@field log? boolean|string  `true` writes under `$XDG_STATE_HOME/chatora`; a string is the file.
---@field notations? table<string, chatora.NotationSpec>  Keyed by the one-character marker.
---@field keymaps? boolean|chatora.Keymaps  `false` maps nothing at all.
---@field open_external_link? 'confirm'|'always'|'never'  What `follow` does on an external URL.
---@field open_video? 'browser'|string[]|fun(url: string): boolean?  Where `follow` sends a moving Gyazo capture: a command with `{url}`, or a function that may decline with `false`.
---@field sidebar? chatora.SidebarConfig
---@field related? chatora.RelatedConfig
---@field edit? chatora.EditConfig
---@field view? chatora.ViewConfig
---@field image? chatora.ImageConfig

-- Every option's meaning is documented in README.md; only defaults live here.
---@type chatora.Config
local defaults = {
  origin = 'https://scrapbox.io',
  default_project = nil,
  server_cmd = nil,
  log = false,
  notations = {},
  keymaps = true,
  open_external_link = 'confirm',
  open_video = 'browser',

  sidebar = {
    width = 32,
    separator = true,
    thumbnails = false,
    refresh_interval = 60,
    tabs = {
      { name = 'すべて' },
      { name = '未読', mine = true, unread = true },
    },
  },
  related = {
    position = 'bottom',
    height = 8,
    width = 40,
    auto_open = true,
  },
  edit = {
    autosave = false,
    sync = { interval = 30, on_focus = true, notify = true },
    save_status = true,
    completion = 'auto',
    autopair = true,
    table_tab = true,
    surround = true,
    paste_indent = true,
    date_format = '%Y-%m-%d %H:%M:%S',
  },
  view = {
    conceal = true,
    pads = true,
    quote = true,
    telomere = { bar = true, scrollbar = true },
    tables = true,
    codeblock_numbers = true,
    file_icon = '󰈔',
    title_margin = 1,
    spacing = { line = 0, code = 0 },
  },
  image = {
    enabled = true,
    backend = 'auto',
    height = 20,
    height_large = nil,
    gallery = true,
    border = true,
  },
}

---@type chatora.Config
M.options = vim.deepcopy(defaults)

local uv = vim.uv or vim.loop

local function file_exists(path)
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == 'file'
end

--- Whether `value` is the one character a conceal can draw. Composing characters do not
--- count: an emoji like `▶️` is U+25B6 followed by a variation selector, which `strchars`
--- reports as two — and Neovim conceals it as the single glyph it looks like.
function M.is_single_char(value)
  return type(value) == 'string' and vim.fn.strchars(value, 1) == 1
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
    if not M.is_single_char(marker) then
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
      if spec.icon ~= nil and not M.is_single_char(spec.icon) then
        vim.notify(
          '[chatora] notations: icon for marker "' .. marker .. '" must be one character, ignoring',
          vim.log.levels.WARN
        )
        spec.icon = nil
      end
      out[marker] = spec
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- keys setup() does not know
-- ---------------------------------------------------------------------------

-- Keys a group may carry beyond its defaults, whose default is nil.
local OPTIONAL = {
  [''] = { default_project = true, server_cmd = true },
  image = { height_large = true },
}

-- The keys of v0.1's flat layout, and where each went. Only named in the warning: the old
-- key does nothing, since carrying it over would keep every old name alive for good.
local RENAMED = {
  project = 'default_project',
  external_link = 'open_external_link',
  video = 'open_video',
  sidebar_width = 'sidebar.width',
  sidebar_separator = 'sidebar.separator',
  sidebar_thumbnails = 'sidebar.thumbnails',
  sidebar_poll = 'sidebar.refresh_interval',
  sidebar_tabs = 'sidebar.tabs',
  related_position = 'related.position',
  related_height = 'related.height',
  related_width = 'related.width',
  related_auto_open = 'related.auto_open',
  autosave = 'edit.autosave',
  sync = 'edit.sync',
  status = 'edit.save_status',
  completion = 'edit.completion',
  surround = 'edit.surround',
  conceal = 'view.conceal',
  pads = 'view.pads',
  quote = 'view.quote',
  telomere = 'view.telomere',
  tables = 'view.tables',
  codeblock_numbers = 'view.codeblock_numbers',
  file_icon = 'view.file_icon',
  title_margin = 'view.title_margin',
  spacing = 'view.spacing',
  images = 'image.enabled',
  image_backend = 'image.backend',
  image_height = 'image.height',
  image_height_large = 'image.height_large',
  image_gallery = 'image.gallery',
  image_border = 'image.border',
}

--- Say once which keys of `opts` mean nothing, at the top and inside each group: a
--- misspelled key would otherwise leave the default in place without a word.
local function warn_unknown(opts)
  local function check(given, known, extra, prefix)
    if type(given) ~= 'table' then
      return
    end
    for key in pairs(given) do
      if known[key] == nil and not (extra and extra[key]) then
        local moved = prefix == '' and RENAMED[key] or nil
        vim.notify_once(
          ('[chatora] setup() に知らないキー `%s%s` があります%s'):format(
            prefix,
            key,
            moved and ('（`' .. moved .. '` になりました）') or ''
          ),
          vim.log.levels.WARN
        )
      end
    end
  end
  check(opts, defaults, OPTIONAL[''], '')
  for _, group in ipairs({ 'sidebar', 'related', 'edit', 'view', 'image' }) do
    check(opts[group], defaults[group], OPTIONAL[group], group .. '.')
  end
end

-- Absolute path of the repo/plugin root, derived from this file's location:
-- lua/chatora/config.lua -> repo root. The repo root doubles as the plugin's
-- runtimepath root so plugin managers can install it straight from GitHub.
local function plugin_root()
  local source = debug.getinfo(1, 'S').source:sub(2)
  return vim.fn.fnamemodify(source, ':p:h:h:h')
end

--- What setup() was last called with (a table, or a function of `ctx`), kept unmerged so
--- `:Chatora reload` re-applies the user's configuration rather than a copy of it merged
--- with defaults.
---@type chatora.Config|fun(ctx: chatora.SetupContext): chatora.Config|nil
M.user_opts = nil

--- Tabs pinned with add_tab after setup, listed after the configured ones. Kept apart
--- from `options`, which is swapped out per project.
---@type chatora.TabSpec[]
M.pinned_tabs = {}

-- Handed to the server once, when it starts, so a project cannot have its own.
local SERVER_KEYS = { 'origin', 'notations', 'log', 'server_cmd' }

-- The answer given with no project, and the ones given per project, for the session:
-- asking again would hand the sidebar new tables and closures for the same tabs, and
-- their fetched pages are carried over by identity.
local base = nil
local per_project = {}

local function resolve(project)
  local opts = M.user_opts
  if type(opts) == 'function' then
    local ok, ret = xpcall(opts, debug.traceback, { project = project })
    if not ok then
      vim.notify('[chatora] setup() の関数でエラーになりました: ' .. tostring(ret), vim.log.levels.ERROR)
      ret = nil
    elseif type(ret) ~= 'table' then
      vim.notify(
        ('[chatora] setup() の関数は設定のテーブルを返してください（%s が返りました）'):format(type(ret)),
        vim.log.levels.WARN
      )
      ret = nil
    end
    opts = ret
  end
  warn_unknown(opts or {})
  local options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
  options.notations = validate_notations(options.notations)
  return options
end

---@param opts? chatora.Config|fun(ctx: chatora.SetupContext): chatora.Config
function M.setup(opts)
  M.user_opts = opts
  M.pinned_tabs = {}
  per_project = {}
  base = resolve(nil)
  M.options = base
end

--- Make `options` the ones for `project` (nil: the ones for no project). Only a setup()
--- given a function has any: it is asked once per project, with `{ project = project }`,
--- and its answer kept for the session. What the server was started with stays as it is.
---@param project? string
function M.use_project(project)
  if type(M.user_opts) ~= 'function' then
    return
  end
  if project == nil then
    M.options = base
    return
  end
  local options = per_project[project]
  if not options then
    options = resolve(project)
    for _, key in ipairs(SERVER_KEYS) do
      if not vim.deep_equal(options[key], base[key]) then
        vim.notify_once(
          ('[chatora] %s はサーバーの起動時に渡すので、プロジェクトごとには変えられません'):format(key),
          vim.log.levels.WARN
        )
        options[key] = base[key]
      end
    end
    per_project[project] = options
  end
  M.options = options
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
---@return chatora.NotationSpec?
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
