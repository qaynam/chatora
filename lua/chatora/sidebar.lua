-- Left sidebar: a project's pages, split into tabbed sources. Each tab keeps
-- its own list and paging cursor; the save-state (✓/●) and unread (▍) marks
-- are derived per render from live buffer state, never cached.
local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')
local page = require('chatora.page')
local spinner = require('chatora.spinner')
local search = require('chatora.search')
local uri = require('chatora.uri')

local buf, win
local project
local line_pages = {}
local line_folders = {}

-- A page's first picture in front of its title, one row tall and this many cells wide, cut
-- square server-side so every row's is the same width. Three cells because that is what
-- snacks gives a square picture drawn inline (its width in cells plus two), and the cells
-- reserved in the line have to match what replaces them. Placements are bound to the
-- window and to the lines they were made on: `thumbs` is emptied whenever either changes,
-- and refilled for the rows on screen.
local THUMB_CELLS = 3
local THUMB_PX = 64
local thumbs = {}
local thumbs_win = nil
local thumbs_generation = 0
local wanted_thumbs = {}
local ns = vim.api.nvim_create_namespace('chatora_sidebar')

local function ensure_hl()
  vim.api.nvim_set_hl(0, 'ChatoraSidebarTitle', { link = 'Title', default = true })
  -- Cosense's web grid borders unread cards in blue; column 0 is the list's
  -- equivalent of a card edge.
  vim.api.nvim_set_hl(0, 'ChatoraSidebarUnread', { fg = '#2d7ff9', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraSidebarUnreadTitle', { bold = true, default = true })
  vim.api.nvim_set_hl(0, 'ChatoraSidebarTabActive', { link = 'TabLineSel', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraSidebarTabInactive', { link = 'TabLine', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraSidebarPin', { link = 'Special', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraSidebarFolder', { link = 'Directory', default = true })
  -- Underline spans the full row, separating rows without spending a line. A hairline
  -- rather than a window border's color, since every row carries one; a color given to
  -- `sidebar_separator` wins.
  local configured = config.options.sidebar.separator
  vim.api.nvim_set_hl(0, 'ChatoraSidebarRow', {
    underline = true,
    sp = type(configured) == 'string' and configured or require('chatora.highlight').hairline(),
    default = true,
  })
end

local function is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Run `fn` with the sidebar's cursor and top line restored afterwards, so a
--- background refresh doesn't scroll the list out from under the reader.
local function keeping_view(fn)
  local view = nil
  if is_open() then
    vim.api.nvim_win_call(win, function()
      view = vim.fn.winsaveview()
    end)
  end
  fn()
  if view and is_open() then
    vim.api.nvim_win_call(win, function()
      view.lnum = math.min(view.lnum, vim.api.nvim_buf_line_count(buf))
      pcall(vim.fn.winrestview, view)
    end)
  end
end

local winutil = require('chatora.winutil')

local function ensure_editor_win()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
  return winutil.ensure_editor_win({ exclude = win })
end

-- ---------------------------------------------------------------------------
-- tabs
-- ---------------------------------------------------------------------------

local DEFAULT_TABS = {
  { name = 'すべて' },
  { name = '未読', mine = true, unread = true },
}

-- What a `sidebar.tabs` entry, or a folder at any depth in one, may say. A key outside
-- this list is a typo the reader would otherwise only notice as a tab that lists everything.
-- `label` and `unread_only` are what v0.1 shipped; still accepted, with a warning.
local LIST_KEYS = {
  label = true,
  name = true,
  icon = true,
  filter = true,
  mine = true,
  related = true,
  pages = true,
  image = true,
  unread = true,
  unread_only = true,
  open = true,
  folders = true,
}

local FOLDER_OPEN = '▾ '
local FOLDER_CLOSED = '▸ '

local tabs = {}
local active = 1

--- Each project's tabs, kept while the session lasts so coming back to one shows its list
--- at once. A list is a few hundred rows of ids and titles — far cheaper to hold than the
--- requests that would rebuild it, and the poll loop brings whichever is on screen up to
--- date anyway.
local sessions = {}

-- Fetched once per session; a `mine` tab cannot query until it lands.
local me = nil

local function new_state()
  return {
    pages = {},
    count = nil,
    scanned = 0,
    loading = false,
    exhausted = false,
    cursor = 1,
    -- `loading` cannot answer "is this empty or just early?": it is false before a
    -- request starts, between batches, and for the whole time a `me` tab waits on
    -- authStatus. Without this an empty list reads as "no results" from the first frame.
    fetched = false,
  }
end

-- The keys that decide what a list holds. One at most: the others narrow or decorate.
local SOURCE_KEYS = { 'filter', 'mine', 'related', 'pages', 'folders' }

--- One list from its spec: a tab, or a folder inside one. `prior` is the list that stood
--- at the same position before a rebuild; its pages are carried over only under the same
--- name, since a reordered or renamed list is a different query.
local function make_list(spec, where, fallback_name, prior)
  for key in pairs(spec) do
    if not LIST_KEYS[key] then
      vim.notify_once(
        ('[chatora] %sに知らないキー `%s` があります（使えるのは name, icon, image, filter, mine, related, pages, unread, open, folders）'):format(
          where,
          key
        ),
        vim.log.levels.WARN
      )
    end
  end
  if spec.pages ~= nil and type(spec.pages) ~= 'function' and type(spec.pages) ~= 'table' then
    vim.notify_once(('[chatora] %sの pages は関数か一覧にしてください'):format(where), vim.log.levels.WARN)
  end
  if spec.folders ~= nil and type(spec.folders) ~= 'function' and type(spec.folders) ~= 'table' then
    vim.notify_once(('[chatora] %sの folders は関数か一覧にしてください'):format(where), vim.log.levels.WARN)
  end
  if spec.related ~= nil and type(spec.related) ~= 'string' and type(spec.related) ~= 'table' then
    vim.notify_once(
      ('[chatora] %sの related はページのタイトルか、その並びにしてください'):format(where),
      vim.log.levels.WARN
    )
  end
  if spec.filter == 'me' then
    vim.notify_once(
      ('[chatora] %sの `filter = \'me\'` は `mine = true` になりました。filter にはページのタイトルを書きます'):format(where),
      vim.log.levels.WARN
    )
  end
  if spec.label ~= nil then
    vim.notify_once(('[chatora] %sの `label` は `name` になりました'):format(where), vim.log.levels.WARN)
  end
  if spec.unread_only ~= nil then
    vim.notify_once(('[chatora] %sの `unread_only` は `unread` になりました'):format(where), vim.log.levels.WARN)
  end
  local sources = {}
  for _, key in ipairs(SOURCE_KEYS) do
    if spec[key] ~= nil and spec[key] ~= false then
      sources[#sources + 1] = key
    end
  end
  if #sources > 1 then
    vim.notify_once(
      ('[chatora] %sの中身を決めるキーは 1 つだけです（%s が一緒にあります）'):format(where, table.concat(sources, ', ')),
      vim.log.levels.WARN
    )
  end
  local name = spec.name or spec.label or fallback_name
  local carried = prior ~= nil and prior.name == name and prior or nil
  local pages = spec.pages
  if type(pages) == 'table' then
    local fixed = pages
    pages = function()
      return fixed
    end
  end
  return {
    name = name,
    where = where,
    icon = spec.icon,
    image = type(spec.image) == 'string' and spec.image ~= '' and spec.image or nil,
    filter = spec.filter ~= 'me' and spec.filter or nil,
    mine = (spec.mine == true or spec.filter == 'me') and true or nil,
    related = (type(spec.related) == 'string' or type(spec.related) == 'table') and spec.related or nil,
    pages = type(pages) == 'function' and pages or nil,
    unread = (spec.unread or spec.unread_only) and true or nil,
    state = carried and carried.state or new_state(),
    carried = carried,
  }
end

--- What the reader's functions get to say. Safe from any callback: a notify off the main
--- loop would fail, and the failure would vanish into the callback. Shown in :messages and
--- written next to the server's lines, so `:Chatora log` has both.
local function make_logger(name)
  return function(...)
    local parts = {}
    for i = 1, select('#', ...) do
      local value = select(i, ...)
      -- One line per call: a record in the log file is a line, and a table would spill over.
      parts[#parts + 1] = type(value) == 'string' and value or vim.inspect(value, { newline = ' ', indent = '' })
    end
    local message = name .. ': ' .. table.concat(parts, ' ')
    local function emit()
      vim.notify('[chatora] ' .. message, vim.log.levels.INFO)
      lsp.notify('chatora/log', { message = message })
    end
    if vim.in_fast_event() then
      vim.schedule(emit)
    else
      emit()
    end
  end
end

--- Run `fn(ctx)`, the reader's own source of rows or folders. It may return the result,
--- or hand it to `ctx.done` later, from wherever it likes: a `done` called off the main
--- loop (a vim.system callback, say) is brought back onto it. `cb` runs once, with the
--- result or with nil and why, and never inside `fn` itself, so what is done with the
--- result cannot be mistaken for the function's own error. Everything the function is
--- given rides on `ctx`, so a later addition never changes its arguments.
local function call_source(fn, what, name, cb)
  local finished, returned, held = false, false, nil
  local function settle(value, why)
    if value == nil then
      cb(nil, why or (what .. ' が結果を返しませんでした'))
    else
      cb(value)
    end
  end
  local function done(value, why)
    if finished then
      return
    end
    finished = true
    if vim.in_fast_event() then
      vim.schedule(function()
        settle(value, why)
      end)
    elseif returned then
      settle(value, why)
    else
      held = { value, why }
    end
  end
  local ok, ret = xpcall(function()
    return fn({ project = project, log = make_logger(name), done = done })
  end, function(e)
    -- Where it broke, since an error out of a C function (table.sort, say) names no line.
    return debug.traceback(tostring(e), 2)
  end)
  returned = true
  if not ok then
    done(nil, what .. ': ' .. tostring(ret))
  elseif ret ~= nil then
    done(ret)
  end
  if held then
    settle(held[1], held[2])
  end
end

--- The folders of `spec`, at any depth, hung on `list`. A folder that holds folders is
--- only a heading: its own state is never fetched. A `folders` function is kept to be
--- asked when the list is first shown (resolve_folders); until then the list is an empty
--- heading, unless the rebuild it is part of can carry the tree the same function gave
--- last time.
local function attach_folders(list, spec, where, prior)
  if type(spec.folders) == 'function' then
    list.folders_fn = spec.folders
    if prior and prior.folders_fn == spec.folders and prior.folders then
      list.folders = prior.folders
      list.folders_resolved = prior.folders_resolved
    else
      list.folders = {}
      list.folders_resolved = false
    end
    return
  end
  if type(spec.folders) ~= 'table' then
    return
  end
  list.folders = {}
  for j, fspec in ipairs(spec.folders) do
    local folder_where = ('%sのフォルダー %d'):format(where, j)
    local folder = make_list(fspec, folder_where, '#' .. j, prior and prior.folders and prior.folders[j] or nil)
    -- Whether the reader left it open outlives a rebuild; the spec only says how it starts.
    folder.open = folder.carried and folder.carried.open or (not folder.carried and fspec.open ~= false)
    attach_folders(folder, fspec, folder_where, folder.carried)
    folder.carried = nil
    list.folders[j] = folder
  end
end

--- Rebuild the tab list from config, carrying each tab's already-fetched pages over.
--- Closing and reopening the sidebar must not cost a full refetch — the poll loop is what
--- keeps the list current.
---
--- @param keep_state boolean False when the project changed: another project's list is
---   not this one's.
local function build_tabs(keep_state)
  local specs = config.options.sidebar.tabs
  if specs == false then
    specs = { DEFAULT_TABS[1] }
  elseif type(specs) ~= 'table' or #specs == 0 then
    specs = DEFAULT_TABS
  end
  if #config.pinned_tabs > 0 then
    specs = vim.list_extend(vim.list_extend({}, specs), config.pinned_tabs)
  end
  local previous = tabs
  tabs = {}
  for i, spec in ipairs(specs) do
    local prior = keep_state and previous[i] or nil
    local where = ('sidebar.tabs の %d 番目'):format(i)
    local tab = make_list(spec, where, '#' .. i, prior)
    attach_folders(tab, spec, where, tab.carried)
    tab.carried = nil
    tabs[i] = tab
  end
  if active > #tabs then
    active = 1
  end
end

--- The lists under `list` that hold pages: itself when it has no folders, else the
--- folders at the bottom of its tree, only the open ones (under open ones) when
--- `open_only`.
local function collect_lists(list, open_only, out)
  if not list.folders then
    out[#out + 1] = list
    return out
  end
  for _, folder in ipairs(list.folders) do
    if not open_only or folder.open then
      collect_lists(folder, open_only, out)
    end
  end
  return out
end

--- Whether anything of `tab` has come in: what tells a tab shown again from one never
--- loaded. The tab's own state says nothing once it has folders, and a heading with
--- folders still to ask for has no lists at all.
local function has_loaded(tab)
  if tab.folders_fn and tab.folders_resolved then
    return true
  end
  for _, list in ipairs(collect_lists(tab, false, {})) do
    if list.state.fetched then
      return true
    end
  end
  return false
end

--- The lists a tab draws.
local function visible_lists(tab)
  return collect_lists(tab, true, {})
end

--- Every node on screen under `list`, headings included: `fn(node)` for the list itself,
--- then for each open folder's subtree.
local function each_visible(list, fn)
  fn(list)
  for _, folder in ipairs(list.folders or {}) do
    if folder.open then
      each_visible(folder, fn)
    end
  end
end

--- A heading whose folders are still to be asked for.
local function folders_pending(node)
  return node.folders_fn ~= nil and not node.folders_resolved
end

--- Every list a tab holds, open or not.
local function all_lists(tab)
  return collect_lists(tab, false, {})
end

--- The `filterType`/`filterValue` pair for a tab, or nil for "no filter". A `mine` tab is
--- the web's filter for the reader's own name: their saved filter when they have one,
--- else the icon of their name.
local function filter_of(tab)
  if tab.mine then
    if not me then
      return nil
    end
    local saved = (me.pageFilters or {})[1]
    if saved and saved.type and saved.value then
      return saved.type, saved.value
    end
    if me.name and me.name ~= '' then
      return 'icon', me.name
    end
    return nil
  end
  local filter = tab.filter
  if filter == nil or filter == false then
    return nil
  end
  -- The web's page filter takes a title and filters by its `.icon` notation; a bare
  -- string here means the same thing.
  if type(filter) == 'string' then
    return 'icon', filter
  end
  if type(filter) == 'table' and filter.type and filter.value then
    return filter.type, filter.value
  end
  return nil
end

local function tabline()
  local parts = {}
  for i, tab in ipairs(tabs) do
    local hl = i == active and 'ChatoraSidebarTabActive' or 'ChatoraSidebarTabInactive'
    local text = (tab.icon and (tab.icon .. ' ') or '') .. tab.name
    -- %<n>@fn@ … %X makes the label clickable; the handler switches to tab n.
    parts[#parts + 1] = ('%%%d@v:lua.chatora_sidebar_tab_click@%%#%s# %s %%*%%X'):format(i, hl, text)
  end
  return table.concat(parts)
end

--- Project and account in the status line: with `P` and `A` a keystroke away, which of
--- each is in front of the reader has to be visible without asking.
local function apply_statusline()
  if not is_open() then
    return
  end
  local who = me and (me.displayName ~= '' and me.displayName or me.name) or nil
  vim.wo[win].statusline = 'chatora: ' .. (project or '') .. (who and ('  ' .. who) or '')
end

local function apply_winbar()
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  vim.wo[win].winbar = tabline()
    .. "%=%{%v:lua.require'chatora.status'.component()%} "
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

-- Forward declarations: sync_spinner's tick calls render, and render calls ensure_buf;
-- both are defined further down.
local render
local ensure_buf

local UNREAD_BAR = '▍'
local READ_BAR = ' '
local PIN_MARK = '󰐃 '

local function thumbnails_on()
  return config.options.sidebar.thumbnails == true
end

local function drop_thumbs()
  thumbs_generation = thumbs_generation + 1
  for _, thumb in pairs(thumbs) do
    if thumb.close then
      pcall(thumb.close)
    end
  end
  thumbs = {}
  thumbs_win = nil
end

--- Place the thumbnails of the rows on screen that have none yet. Only what is on screen:
--- every picture is a fetch the first time, and a list is a hundred rows long.
local function sync_thumbs()
  if not is_open() or not thumbnails_on() then
    return
  end
  if thumbs_win ~= win then
    drop_thumbs()
    thumbs_win = win
  end
  local top, bottom
  vim.api.nvim_win_call(win, function()
    top, bottom = vim.fn.line('w0'), vim.fn.line('w$')
  end)
  local margin = bottom - top + 1
  local generation = thumbs_generation
  for row, wanted in pairs(wanted_thumbs) do
    if row + 1 >= top - margin and row + 1 <= bottom + margin and not thumbs[row] then
      local entry = { url = wanted.url }
      thumbs[row] = entry
      require('chatora.images').place_one(buf, project, wanted.url, row, wanted.col, function(placement)
        -- The list moved on while the picture was being fetched.
        if thumbs_generation ~= generation or thumbs[row] ~= entry then
          pcall(placement.close)
          return
        end
        entry.close = placement.close
      end, { thumb = THUMB_PX, cells = THUMB_CELLS, screen_col = wanted.screen_col, conceal = true })
    end
  end
end

--- The save-state glyph for a page, or nil when it has no open buffer.
local function status_of(entry)
  if not (project and entry.title) then
    return nil
  end
  return require('chatora.status').icon_for_uri(uri.format(project, entry.title))
end

--- True while `entry` is listed as unread and has no open buffer. Opening a
--- page marks it read server-side, but the list is only refetched on demand,
--- so the bar clears locally the moment its buffer exists.
local function is_unread(entry)
  return entry.unread == true and status_of(entry) == nil
end

--- Animate only while a list on screen has nothing to show yet: a list with rows
--- already listed refreshes in place, and a settled empty one is just empty.
local function sync_spinner()
  local tab = tabs[active]
  local waiting = false
  if tab and is_open() then
    each_visible(tab, function(node)
      if node.folders then
        waiting = waiting or folders_pending(node)
      elseif not node.state.fetched and #node.state.pages == 0 then
        waiting = true
      end
    end)
  end
  if waiting then
    spinner.subscribe('sidebar', function()
      render()
    end)
  else
    spinner.release('sidebar')
  end
end

function render()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  -- Writing lines into an unloaded buffer loads it, and a buffer loaded that way comes
  -- back with option defaults.
  ensure_buf()
  require('chatora.render').quiet_indent_guides(buf)
  local separators = config.options.sidebar.separator ~= false
  local tab = tabs[active]
  line_pages, line_folders = {}, {}
  local lines = {}
  local rows = {}
  local pad = thumbnails_on() and string.rep(' ', THUMB_CELLS + 1) or ''
  local function add_page(p, depth)
    local unread = is_unread(p)
    local icon, hl_group = status_of(p)
    -- Cosense sorts pinned pages to the front; the mark says why they are there.
    local pinned = type(p.pin) == 'number' and p.pin > 0
    local bar = unread and UNREAD_BAR or READ_BAR
    local indent = string.rep('  ', depth or 0)
    lines[#lines + 1] = bar .. pad .. indent .. (pinned and PIN_MARK or '') .. (p.title or '(untitled)')
    rows[#rows + 1] = {
      unread = unread,
      icon = icon,
      hl_group = hl_group,
      pin_at = #bar + #pad + #indent,
      pin_width = pinned and #PIN_MARK or 0,
      thumb = pad ~= '' and type(p.image) == 'string' and p.image ~= '' and { url = p.image, col = #bar, screen_col = 1 }
        or nil,
    }
    line_pages[#lines] = p
  end
  local function add_note(state, indent)
    lines[#lines + 1] = indent .. (state.fetched and '(該当なし)' or (spinner.frame() .. ' 読み込み中…'))
    rows[#rows + 1] = { note = true }
  end
  local function add_folder(folder, depth)
    local indent = string.rep('  ', depth)
    local glyph = folder.open and FOLDER_OPEN or FOLDER_CLOSED
    lines[#lines + 1] = indent .. glyph .. pad .. (folder.icon and (folder.icon .. ' ') or '') .. folder.name
    rows[#rows + 1] = {
      folder = true,
      thumb = pad ~= '' and folder.image and { url = folder.image, col = #indent + #glyph, screen_col = #indent + 1 }
        or nil,
    }
    line_folders[#lines] = folder
    if not folder.open then
      return
    end
    if folder.folders then
      for _, child in ipairs(folder.folders) do
        add_folder(child, depth + 1)
      end
      if #folder.folders == 0 then
        add_note({ fetched = not folders_pending(folder) }, indent .. '  ')
      end
      return
    end
    for _, p in ipairs(folder.state.pages) do
      add_page(p, depth)
    end
    if #folder.state.pages == 0 then
      add_note(folder.state, indent .. '  ')
    end
  end
  if tab and tab.folders then
    for _, folder in ipairs(tab.folders) do
      add_folder(folder, 0)
    end
    if #lines == 0 then
      add_note({ fetched = not folders_pending(tab) }, ' ')
    end
  else
    local state = tab and tab.state or new_state()
    for _, p in ipairs(state.pages) do
      add_page(p)
    end
    if #lines == 0 then
      add_note(state, ' ')
    end
  end
  sync_spinner()

  -- The lines are only written when they differ: a refresh of the marks alone comes on
  -- every keystroke in a page, and rewriting the lines would collapse the extmarks the
  -- thumbnails ride on, so each refresh would take every picture down and draw it again.
  local changed = not vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
  if changed then
    drop_thumbs()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end
  wanted_thumbs = {}
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, row_info in ipairs(rows) do
    local row = i - 1
    if row_info.thumb then
      wanted_thumbs[row] = row_info.thumb
    end
    if row_info.folder then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_line = row + 1, hl_group = 'ChatoraSidebarFolder' })
    elseif not row_info.note then
      if separators then
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = 'ChatoraSidebarRow' })
      end
      if row_info.unread then
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
          end_col = #UNREAD_BAR,
          hl_group = 'ChatoraSidebarUnread',
        })
        vim.api.nvim_buf_set_extmark(buf, ns, row, #UNREAD_BAR, {
          end_line = row + 1,
          hl_group = 'ChatoraSidebarUnreadTitle',
        })
      end
      if row_info.pin_width > 0 then
        vim.api.nvim_buf_set_extmark(buf, ns, row, row_info.pin_at, {
          end_col = row_info.pin_at + row_info.pin_width,
          hl_group = 'ChatoraSidebarPin',
        })
      end
      if row_info.icon then
        -- Right-aligned so the save state never pushes titles around, and the
        -- left edge stays reserved for the unread border.
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
          virt_text = { { row_info.icon .. ' ', row_info.hl_group } },
          virt_text_pos = 'right_align',
        })
      end
    end
  end
  -- Rendering marks an acwrite buffer modified, which makes Neovim offer to save it on
  -- exit. This is a view; there is nothing to save.
  vim.bo[buf].modified = false
  apply_winbar()
  sync_thumbs()
end

--- Re-render the save-state / unread marks from cached pages, without refetching.
function M.refresh_marks()
  render()
end

-- ---------------------------------------------------------------------------
-- fetching
-- ---------------------------------------------------------------------------

local PAGE_SIZE = 100
-- An unread tab thins each batch client-side, so a batch can arrive empty while
-- plenty of unread pages remain further down. Keep pulling until the tab has
-- something worth showing (or the project runs out).
local MIN_ROWS = 20
-- But not through the whole project in one go: batches go out back to back, and a
-- thousand pages of them within a second is what Cosense answers with 429, after which
-- even the credential check fails. Past this many, the rest comes as the reader scrolls.
local AUTO_SCAN_LIMIT = 500

--- Request params for one batch of `tab`, or nil when it cannot query yet.
local function batch_params(tab, skip)
  local filter_type, filter_value = filter_of(tab)
  if tab.mine and not filter_type then
    return nil
  end
  return {
    project = project,
    skip = skip,
    limit = PAGE_SIZE,
    unreadOnly = tab.unread or nil,
    filterType = filter_type,
    filterValue = filter_value,
  }
end

--- A tab whose list comes whole rather than in batches: the related pages of a title, or
--- whatever the reader's `pages` function hands over.
local function comes_whole(tab)
  return tab.related ~= nil or tab.pages ~= nil
end

--- Only rows the renderer can draw: a title each, in the order given. A table without one
--- is said out loud, since a row is keyed by `title` while a folder is keyed by `name`,
--- and the one is easily written for the other.
local function as_rows(list, name)
  local rows = {}
  for _, entry in ipairs(type(list) == 'table' and list or {}) do
    if type(entry) == 'string' then
      rows[#rows + 1] = { title = entry }
    elseif type(entry) == 'table' and entry.title then
      rows[#rows + 1] = entry
    elseif type(entry) == 'table' then
      vim.notify_once(
        ('[chatora] %s: pages の要素に title がありません（行は title、フォルダーは name です）'):format(name),
        vim.log.levels.WARN
      )
    end
  end
  return rows
end

--- The pages around every title in `titles`, as one list: a page linked from two of them
--- appears once. Nil with a message when any of the requests failed, since a list missing
--- one title's pages would read as those pages not existing.
local function fetch_linked(titles, cb)
  local pages, seen, failed = {}, {}, nil
  local remaining = #titles
  for _, title in ipairs(titles) do
    lsp.request('chatora/relatedPages', { project = project, title = title }, function(err, result)
      if err or not result or result.ok == false then
        failed = failed or (result and result.message) or (err and tostring(err)) or 'request failed'
      else
        for _, p in ipairs(result.links1hop or {}) do
          local key = p.id or p.title
          if not seen[key] then
            seen[key] = true
            pages[#pages + 1] = p
          end
        end
      end
      remaining = remaining - 1
      if remaining > 0 then
        return
      end
      if failed then
        cb(nil, failed)
        return
      end
      table.sort(pages, function(a, b)
        return (a.updated or 0) > (b.updated or 0)
      end)
      cb(pages)
    end)
  end
end

--- The whole list of `tab`, or nil with a message. A `pages` function may return the
--- list or hand it to `done` later, whichever suits what it asks; the related pages of
--- a title come newest first, as the other tabs are.
local function fetch_whole(tab, cb)
  if tab.pages then
    call_source(tab.pages, 'pages', tab.name, function(list, why)
      if list == nil then
        cb(nil, why)
      else
        cb(as_rows(list, tab.name))
      end
    end)
    return
  end
  fetch_linked(type(tab.related) == 'table' and tab.related or { tab.related }, cb)
end

--- Fetch the next batch of `list`, which belongs to tab `index`, and draw it if that tab is
--- still the one on screen.
local function load_list(list, index)
  local state = list.state
  if state.loading or state.exhausted then
    return
  end

  if comes_whole(list) then
    state.loading = true
    fetch_whole(list, function(pages, why)
      state.loading = false
      state.fetched = true
      state.exhausted = true
      if not pages then
        vim.notify('[chatora] ' .. why, vim.log.levels.ERROR)
      else
        state.pages = pages
        state.count = #pages
        state.scanned = #pages
      end
      if index == active then
        render()
      end
    end)
    return
  end

  -- Paging advances by pages *scanned*, not kept: an unread tab may drop most
  -- of a batch, and skipping by the kept count would re-fetch what it dropped.
  local params = batch_params(list, state.scanned)
  if not params then
    return
  end
  state.loading = true

  lsp.request_ok('chatora/listPages', params, function(result)
    state.loading = false
    state.fetched = true
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      return
    end
    state.count = result.count or state.count
    local scanned = result.scanned or #(result.pages or {})
    state.scanned = state.scanned + scanned
    for _, p in ipairs(result.pages or {}) do
      state.pages[#state.pages + 1] = p
    end
    if scanned == 0 or (state.count and state.scanned >= state.count) then
      state.exhausted = true
    end
    if index == active then
      render()
      if not state.exhausted and #state.pages < MIN_ROWS and state.scanned < AUTO_SCAN_LIMIT then
        load_list(list, index)
      end
    end
  end)
end

--- Fetch what the active tab is missing (infinite scroll): every list on screen still
--- without its first batch; once they all have one, the scroll reaching the bottom extends
--- the last of them, which is what the bottom belongs to.
--- Ask a heading's `folders` function for its folders and hang them on it, carrying over
--- what a folder of the same name held before, then draw and fetch what came.
local function resolve_folders(node, index)
  if node.folders_loading then
    return
  end
  node.folders_loading = true
  local previous = node.folders
  call_source(node.folders_fn, 'folders', node.name, function(specs, why)
    node.folders_loading = false
    node.folders_resolved = true
    if specs == nil then
      vim.notify('[chatora] ' .. why, vim.log.levels.ERROR)
      specs = {}
    end
    attach_folders(node, { folders = type(specs) == 'table' and specs or {} }, node.where, { folders = previous })
    if index == active then
      render()
      M.load_more()
    end
  end)
end

function M.load_more()
  local index = active
  local tab = tabs[index]
  if not (project and tab) then
    return
  end
  each_visible(tab, function(node)
    if node.folders and folders_pending(node) then
      resolve_folders(node, index)
    end
  end)
  local lists = visible_lists(tab)
  local pending = false
  for _, list in ipairs(lists) do
    if not list.state.fetched then
      load_list(list, index)
      pending = true
    end
  end
  if pending or #lists == 0 then
    return
  end
  load_list(lists[#lists], index)
end

--- Pin one more tab, as an entry at the end of `sidebar.tabs` would, in every project.
function M.add_tab(spec)
  config.pinned_tabs[#config.pinned_tabs + 1] = spec
  build_tabs(true)
  if is_open() then
    apply_winbar()
    render()
    M.load_more()
  end
end

function M.reload()
  if not project then
    return
  end
  local function reset(node)
    node.state = new_state()
    if node.folders_fn then
      node.folders_resolved = false
    end
    for _, folder in ipairs(node.folders or {}) do
      reset(folder)
    end
  end
  for _, tab in ipairs(tabs) do
    reset(tab)
  end
  render()
  M.load_more()
end

-- ---------------------------------------------------------------------------
-- polling
-- ---------------------------------------------------------------------------

local uv = vim.uv or vim.loop
local poll_timer = nil

local function identity_of(entry)
  return (entry.id or entry.title or '') .. '\0' .. tostring(entry.updated or '')
end

--- Signature of the first `limit` rows: what a poll compares to decide whether
--- anything is worth redrawing.
local function head_signature(pages, limit)
  local parts = {}
  for i = 1, math.min(limit, #pages) do
    parts[i] = identity_of(pages[i])
  end
  return table.concat(parts, '\1')
end

--- Splice a freshly fetched first batch onto the front, dropping the entries it
--- supersedes further down. The list is sorted by update time, so an edited
--- page reappears at the top and must not also linger at its old position.
local function merge_head(fresh, existing)
  local seen = {}
  for _, p in ipairs(fresh) do
    seen[p.id or p.title] = true
  end
  local merged = { unpack(fresh) }
  for _, p in ipairs(existing) do
    if not seen[p.id or p.title] then
      merged[#merged + 1] = p
    end
  end
  return merged
end

--- Refetch the first batch of `list` (of tab `index`) and adopt it only if it differs.
local function poll_list(list, index)
  local state = list.state
  if state.loading then
    return
  end
  if comes_whole(list) then
    fetch_whole(list, function(fresh)
      if not fresh or index ~= active or not is_open() then
        return
      end
      if head_signature(fresh, #fresh) == head_signature(state.pages, #state.pages) then
        return
      end
      state.pages = fresh
      state.count = #fresh
      keeping_view(render)
    end)
    return
  end
  local params = batch_params(list, 0)
  if not params then
    return
  end

  lsp.request('chatora/listPages', params, function(err, result)
    if err or not result or result.ok == false or index ~= active or not is_open() then
      return
    end
    local fresh = result.pages or {}
    if head_signature(fresh, #fresh) == head_signature(state.pages, #fresh) then
      return
    end
    state.count = result.count or state.count
    state.pages = merge_head(fresh, state.pages)
    keeping_view(render)
  end)
end

--- Refetch what the active tab shows. The requests are asynchronous and the redraw is
--- skipped when nothing changed, so an idle project costs nothing but one request per
--- list per interval.
function M.poll()
  local index = active
  local tab = tabs[index]
  if not (project and tab and is_open()) then
    return
  end
  for _, list in ipairs(visible_lists(tab)) do
    poll_list(list, index)
  end
end

local function stop_polling()
  if poll_timer then
    poll_timer:stop()
    poll_timer:close()
    poll_timer = nil
  end
end

local function start_polling()
  stop_polling()
  local seconds = config.options.sidebar.refresh_interval
  if type(seconds) ~= 'number' or seconds <= 0 then
    return
  end
  local interval = math.max(5000, math.floor(seconds * 1000))
  poll_timer = uv.new_timer()
  poll_timer:start(interval, interval, vim.schedule_wrap(function()
    if is_open() then
      M.poll()
    else
      stop_polling()
    end
  end))
end

-- ---------------------------------------------------------------------------
-- tab switching
-- ---------------------------------------------------------------------------

--- Show tab `index` (1-based, clamped), fetching its first batch on demand.
--- Put the cursor back where this tab left it, so returning to a list — by switching
--- tabs or by reopening the sidebar — lands where the reader was, not at the top.
local function restore_cursor()
  if not (win and vim.api.nvim_win_is_valid(win) and tabs[active]) then
    return
  end
  local line = math.min(tabs[active].state.cursor or 1, vim.api.nvim_buf_line_count(buf))
  pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, line), 0 })
end

--- Record the cursor for the tab currently showing, before something replaces it.
local function remember_cursor()
  if win and vim.api.nvim_win_is_valid(win) and tabs[active] then
    tabs[active].state.cursor = vim.api.nvim_win_get_cursor(win)[1]
  end
end

function M.select_tab(index)
  if #tabs == 0 or not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  index = math.max(1, math.min(#tabs, index))
  if index ~= active then
    remember_cursor()
    active = index
  end
  render()
  restore_cursor()
  M.load_more()
end

function M.next_tab(step)
  if #tabs == 0 then
    return
  end
  M.select_tab(((active - 1 + (step or 1)) % #tabs) + 1)
end

-- Winbar click regions call this by name; `minwid` is the tab index encoded in
-- the `%<n>@…@` label.
function _G.chatora_sidebar_tab_click(minwid)
  M.select_tab(minwid)
end

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------

--- Open or close a folder, fetching its list the first time it opens.
function M.toggle_folder(folder)
  folder.open = not folder.open
  render()
  if folder.open then
    M.load_more()
  end
end

--- Open what is under the cursor: a page, a folder (opened or closed), or a row that
--- brought its own `action`, which runs in the editor window instead of opening a page.
function M.open_current()
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local folder = line_folders[lnum]
  if folder then
    M.toggle_folder(folder)
    return
  end
  local p = line_pages[lnum]
  if not p or not p.title then
    return
  end
  local target = ensure_editor_win()
  if type(p.action) == 'function' then
    -- Run with the editor window current: the sidebar's own window refuses to show
    -- another buffer ('winfixbuf'), so an `:edit` in the action would fail there.
    if vim.api.nvim_win_is_valid(target) then
      vim.api.nvim_set_current_win(target)
    end
    p.action(p, target)
    return
  end
  page.open(project, p.title, target)
end

function M.new_page()
  page.open_untitled(project, ensure_editor_win())
end

function M.search()
  search.run(project)
end

function M.close()
  drop_thumbs()
  if is_open() then
    remember_cursor()
    vim.api.nvim_win_close(win, true)
  end
  win = nil
  stop_polling()
end

--- Close the sidebar if it is showing, else (re)open it on the last project.
--- Falls back to the full open flow when there is no project yet.
function M.toggle()
  if is_open() then
    M.close()
  elseif project then
    M.open(project)
  else
    require('chatora').open()
  end
end

local function setup_keymaps()
  local function opts(desc)
    return { buffer = buf, nowait = true, silent = true, desc = desc }
  end
  vim.keymap.set('n', '<CR>', function() M.open_current() end, opts('chatora: ページを開く'))
  -- neo-tree parity: l descends into the row under the cursor.
  vim.keymap.set('n', 'l', function() M.open_current() end, opts('chatora: ページを開く'))
  vim.keymap.set('n', 'R', function() M.reload() end, opts('chatora: 一覧を再読込'))
  vim.keymap.set('n', 's', function() M.search() end, opts('chatora: ページ検索'))
  vim.keymap.set('n', 'n', function() M.new_page() end, opts('chatora: 新規ページ'))
  vim.keymap.set('n', 'P', function() require('chatora').switch_project() end, opts('chatora: プロジェクト切替'))
  vim.keymap.set('n', 'A', function() require('chatora').switch_account() end, opts('chatora: アカウント切替'))
  vim.keymap.set('n', 'q', function() M.close() end, opts('chatora: サイドバーを閉じる'))
  vim.keymap.set('n', '<Tab>', function() M.next_tab(1) end, opts('chatora: 次のタブ'))
  vim.keymap.set('n', '<S-Tab>', function() M.next_tab(-1) end, opts('chatora: 前のタブ'))
  for i = 1, 9 do
    vim.keymap.set('n', tostring(i), function() M.select_tab(i) end, opts('chatora: タブ ' .. i))
  end
end

--- Options, mappings and the scroll autocommand of the sidebar buffer.
local function configure_buf()
  -- acwrite (with page.lua's no-op chatora://* BufWriteCmd) so a reflexive
  -- :wq closes the window instead of E382.
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'chatora_sidebar'
  setup_keymaps()
  -- Infinite scroll: fetch the next batch when the cursor nears the end.
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = vim.api.nvim_create_augroup('ChatoraSidebarBuf', { clear = true }),
    buffer = buf,
    callback = function()
      if not (win and vim.api.nvim_win_is_valid(win)) then
        return
      end
      local lnum = vim.api.nvim_win_get_cursor(win)[1]
      if lnum > vim.api.nvim_buf_line_count(buf) - 20 then
        M.load_more()
      end
    end,
  })
end

--- The sidebar's buffer, created on first open and configured again whenever it was
--- unloaded: `:bdelete` keeps the buffer — and its name, so a replacement carrying the same
--- one fails with E95 — but drops its options and its buffer-local mappings.
function ensure_buf()
  local exists = buf ~= nil and vim.api.nvim_buf_is_valid(buf)
  if exists and vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  if not exists then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, 'chatora://sidebar')
  end
  configure_buf()
end

--- Open the sidebar on `project`, listing its pages. Focuses the sidebar window unless
--- `opts.focus` is false.
function M.open(proj, opts)
  local same_project = project == proj
  if not same_project then
    -- New pages and searches belong to the project in front of the reader, not to
    -- whichever one the session started on; so does the configuration read below.
    require('chatora').set_project(proj)
    if project then
      sessions[project] = { tabs = tabs, active = active }
    end
    local kept = sessions[proj]
    tabs = kept and kept.tabs or {}
    active = kept and kept.active or 1
  end
  project = proj
  ensure_hl()
  -- A project seen before keeps its pages; a new one starts empty either way.
  build_tabs(true)

  ensure_buf()

  local focus = not (opts and opts.focus == false)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    local origin = vim.api.nvim_get_current_win()
    vim.cmd('topleft ' .. tostring(config.options.sidebar.width) .. 'vsplit')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    -- Scrolling brings rows on screen whose thumbnails were never fetched.
    vim.api.nvim_create_autocmd('WinScrolled', {
      group = vim.api.nvim_create_augroup('ChatoraSidebarScroll', { clear = true }),
      pattern = tostring(win),
      callback = sync_thumbs,
    })
    if not focus and vim.api.nvim_win_is_valid(origin) then
      vim.api.nvim_set_current_win(origin)
    end
  elseif focus then
    vim.api.nvim_set_current_win(win)
  end

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  -- Every gutter off: a sign/fold/number column would indent the list away
  -- from the window edge, and column 0 is the unread border.
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].foldcolumn = '0'
  vim.wo[win].statuscolumn = ''
  vim.wo[win].cursorline = true
  vim.wo[win].winfixwidth = true
  -- Pin the window to its buffer: opening a file while the sidebar is
  -- focused must not hijack this window (E1513 instead).
  vim.wo[win].winfixbuf = true
  -- The cells a thumbnail replaces are concealed, which only takes effect at this level.
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = 'nvc'
  apply_statusline()
  apply_winbar()

  lsp.ensure_start(buf)
  -- Reopening shows what is already loaded; the poll loop below brings it up to date in
  -- the background. Only a first open (or a project switch) has nothing to show, and
  -- loading that one tab must not throw the others' pages away.
  if #tabs > 0 and has_loaded(tabs[active]) then
    render()
    restore_cursor()
  else
    render()
    M.load_more()
  end
  start_polling()

  -- The filtered tabs need the user's saved pageFilters; fetch once, then let
  -- whichever tab is showing pick up its now-resolvable query.
  if not me then
    lsp.request('chatora/authStatus', {}, function(err, result)
      me = (not err) and result and result.ok ~= false and result.user or nil
      apply_statusline()
      if me then
        M.load_more()
        return
      end
      -- A tab whose filter needs `me` can never query now. Settle it to its empty state
      -- rather than leaving a spinner running for a request that will not arrive.
      for _, tab in ipairs(tabs) do
        for _, list in ipairs(all_lists(tab)) do
          if list.mine then
            list.state.fetched = true
          end
        end
      end
      render()
    end)
  end
end

-- Keep the marks in sync with buffer modified state. BufModifiedSet alone is
-- not enough: it doesn't fire for API-driven buffer edits, so listen to
-- text-change events too (page.lua additionally reports state transitions
-- through chatora.status after open/save).
local augroup = vim.api.nvim_create_augroup('ChatoraSidebar', { clear = true })

vim.api.nvim_create_autocmd({ 'BufModifiedSet', 'TextChanged', 'TextChangedI' }, {
  group = augroup,
  pattern = 'cosense://*',
  callback = function()
    vim.schedule(M.refresh_marks)
  end,
})

-- The sidebar lists the project the reader is actually in: following a link into another
-- project moves it there, and coming back to the first page moves it back.
vim.api.nvim_create_autocmd('BufEnter', {
  group = augroup,
  pattern = 'cosense://*',
  callback = function(ev)
    if not is_open() then
      return
    end
    local proj = uri.parse(vim.api.nvim_buf_get_name(ev.buf))
    if not proj or proj == project then
      return
    end
    -- The cursor stays where the reader put it; only the list moves.
    M.open(proj, { focus = false })
  end,
})

return M
