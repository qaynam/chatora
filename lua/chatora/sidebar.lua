-- Left sidebar listing a project's pages (infinite-scroll via
-- chatora/listPages), split into neo-tree-style sources shown as tabs in the
-- winbar. Each tab keeps its own page list and paging cursor; save-state (✓/●)
-- and unread (▍) marks are derived per render from live buffer state.
local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')
local page = require('chatora.page')
local search = require('chatora.search')
local uri = require('chatora.uri')

local buf, win
local project
local line_pages = {}
local ns = vim.api.nvim_create_namespace('chatora_sidebar')

local function ensure_hl()
  vim.api.nvim_set_hl(0, 'ChatoraSidebarTitle', { link = 'Title', default = true })
  -- Cosense's web grid marks unread pages with a blue top border; a list has no
  -- card edge to colour, so the bar sits between the save mark and the title.
  vim.api.nvim_set_hl(0, 'ChatoraSidebarUnread', { fg = '#2d7ff9', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraSidebarUnreadTitle', { bold = true, default = true })
  vim.api.nvim_set_hl(0, 'ChatoraSidebarTabActive', { link = 'TabLineSel', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraSidebarTabInactive', { link = 'TabLine', default = true })
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
  { label = 'すべて' },
  -- Cosense's own saved filter (`/api/users/me`'s pageFilters), narrowed to
  -- what hasn't been read yet — the sidebar equivalent of scanning the web
  -- grid for blue borders under your own icon filter.
  { label = '未読', filter = 'me', unread_only = true },
}

--- Resolved tab specs, one `state` each. Rebuilt whenever the config changes.
local tabs = {}
local active = 1

-- pageFilters from the authenticated user, fetched once per session; a `filter
-- = 'me'` tab has no query until this arrives.
local me = nil

local function new_state()
  return { pages = {}, count = nil, scanned = 0, loading = false, exhausted = false, cursor = 1 }
end

local function build_tabs()
  local specs = config.options.sidebar_tabs
  if specs == false then
    specs = { DEFAULT_TABS[1] }
  elseif type(specs) ~= 'table' or #specs == 0 then
    specs = DEFAULT_TABS
  end
  tabs = {}
  for i, spec in ipairs(specs) do
    tabs[i] = vim.tbl_extend('force', { label = spec.label or ('#' .. i) }, spec, { state = new_state() })
  end
  if active > #tabs then
    active = 1
  end
end

--- The `filterType`/`filterValue` pair for a tab, or nil for "no filter".
--- `filter = 'me'` resolves to the signed-in user's first saved page filter,
--- falling back to an icon filter on their own name.
local function filter_of(tab)
  local filter = tab.filter
  if filter == nil or filter == false then
    return nil
  end
  if filter == 'me' then
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
  if type(filter) == 'table' and filter.type and filter.value then
    return filter.type, filter.value
  end
  return nil
end

local function tabline()
  local parts = {}
  for i, tab in ipairs(tabs) do
    local hl = i == active and 'ChatoraSidebarTabActive' or 'ChatoraSidebarTabInactive'
    -- %<n>@fn@ … %X makes the label clickable; the handler switches to tab n.
    parts[#parts + 1] = ('%%%d@v:lua.chatora_sidebar_tab_click@%%#%s# %s %%*%%X')
      :format(i, hl, tab.label)
  end
  return table.concat(parts)
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

local BLANK_MARK = '  '

--- The save-state glyph for a listed page, padded to the 2-cell mark column.
--- Pages with no open buffer get blanks.
local function mark_for(entry)
  if not (project and entry.title) then
    return BLANK_MARK, nil
  end
  local icon, hl_group = require('chatora.status').icon_for_uri(uri.format(project, entry.title))
  if not icon then
    return BLANK_MARK, nil
  end
  return icon .. ' ', hl_group
end

local UNREAD_BAR = '▍'
local READ_BAR = ' '

--- True while `entry` is listed as unread and has no open buffer. Opening a
--- page marks it read server-side, but the list is only refetched on demand,
--- so the bar clears locally the moment its buffer exists.
local function is_unread(entry)
  if not (entry.unread and project and entry.title) then
    return false
  end
  return require('chatora.status').icon_for_uri(uri.format(project, entry.title)) == nil
end

local function render()
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local state = tabs[active] and tabs[active].state or new_state()
  line_pages = {}
  local lines = {}
  local marks = {}
  for i, p in ipairs(state.pages) do
    local mark, hl_group = mark_for(p)
    local unread = is_unread(p)
    local bar = unread and UNREAD_BAR or READ_BAR
    lines[i] = mark .. bar .. (p.title or '(untitled)')
    marks[i] = { mark_width = #mark, bar_width = #bar, hl_group = hl_group, unread = unread }
    line_pages[i] = p
  end
  if #lines == 0 then
    lines = { state.loading and '   読み込み中…' or '   (該当なし)' }
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, mark in ipairs(marks) do
    local row = i - 1
    if mark.hl_group then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        end_col = mark.mark_width,
        hl_group = mark.hl_group,
      })
    end
    if mark.unread then
      vim.api.nvim_buf_set_extmark(buf, ns, row, mark.mark_width, {
        end_col = mark.mark_width + mark.bar_width,
        hl_group = 'ChatoraSidebarUnread',
      })
      vim.api.nvim_buf_set_extmark(buf, ns, row, mark.mark_width + mark.bar_width, {
        end_line = row + 1,
        hl_group = 'ChatoraSidebarUnreadTitle',
      })
    end
  end
  vim.bo[buf].modifiable = false
  apply_winbar()
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

--- Fetch the next batch for the active tab (infinite scroll).
function M.load_more()
  local index = active
  local tab = tabs[index]
  if not (project and tab) then
    return
  end
  local state = tab.state
  if state.loading or state.exhausted then
    return
  end

  local filter_type, filter_value = filter_of(tab)
  if tab.filter == 'me' and not filter_type then
    -- The user's saved filters haven't arrived yet; open() re-runs this once
    -- authStatus lands.
    return
  end

  state.loading = true
  local params = {
    project = project,
    -- Paging advances by pages *scanned*, not kept: an unread tab may drop most
    -- of a batch, and skipping by the kept count would re-fetch what it dropped.
    skip = state.scanned,
    limit = PAGE_SIZE,
    unreadOnly = tab.unread_only or nil,
    filterType = filter_type,
    filterValue = filter_value,
  }

  lsp.request_ok('chatora/listPages', params, function(result)
    state.loading = false
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      return
    end
    state.count = result.count or state.count
    local scanned = result.scanned or #(result.pages or {})
    state.scanned = state.scanned + scanned
    for _, p in ipairs(result.pages or {}) do
      state.pages[#state.pages + 1] = p
    end
    -- A batch that scanned nothing means the project is exhausted; so does
    -- reaching the reported total.
    if scanned == 0 or (state.count and state.scanned >= state.count) then
      state.exhausted = true
    end
    if index == active then
      render()
      if not state.exhausted and #state.pages < MIN_ROWS then
        M.load_more()
      end
    end
  end)
end

function M.reload()
  if not project then
    return
  end
  for _, tab in ipairs(tabs) do
    tab.state = new_state()
  end
  render()
  M.load_more()
end

-- ---------------------------------------------------------------------------
-- tab switching
-- ---------------------------------------------------------------------------

--- Show tab `index` (1-based, clamped), fetching its first batch on demand.
function M.select_tab(index)
  if #tabs == 0 or not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  index = math.max(1, math.min(#tabs, index))
  if index ~= active then
    -- Remember where the cursor was so switching back feels like returning to
    -- the same list rather than to its top.
    if win and vim.api.nvim_win_is_valid(win) then
      tabs[active].state.cursor = vim.api.nvim_win_get_cursor(win)[1]
    end
    active = index
  end
  render()
  if win and vim.api.nvim_win_is_valid(win) then
    local line = math.min(tabs[active].state.cursor or 1, vim.api.nvim_buf_line_count(buf))
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, line), 0 })
  end
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

function M.open_current()
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local p = line_pages[lnum]
  if not p or not p.title then
    return
  end
  local target = ensure_editor_win()
  page.open(project, p.title, target)
end

function M.new_page()
  vim.ui.input({ prompt = 'New page title: ' }, function(title)
    if not title or title == '' then
      return
    end
    local target = ensure_editor_win()
    page.open(project, title, target)
  end)
end

function M.search()
  search.run(project)
end

function M.close()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
end

local function setup_keymaps()
  local function opts(desc)
    return { buffer = buf, nowait = true, silent = true, desc = desc }
  end
  vim.keymap.set('n', '<CR>', function() M.open_current() end, opts('chatora: ページを開く'))
  vim.keymap.set('n', 'R', function() M.reload() end, opts('chatora: 一覧を再読込'))
  vim.keymap.set('n', 's', function() M.search() end, opts('chatora: ページ検索'))
  vim.keymap.set('n', 'n', function() M.new_page() end, opts('chatora: 新規ページ'))
  vim.keymap.set('n', 'P', function() require('chatora').switch_project() end, opts('chatora: プロジェクト切替'))
  vim.keymap.set('n', 'q', function() M.close() end, opts('chatora: サイドバーを閉じる'))
  vim.keymap.set('n', '<Tab>', function() M.next_tab(1) end, opts('chatora: 次のタブ'))
  vim.keymap.set('n', '<S-Tab>', function() M.next_tab(-1) end, opts('chatora: 前のタブ'))
  for i = 1, 9 do
    vim.keymap.set('n', tostring(i), function() M.select_tab(i) end, opts('chatora: タブ ' .. i))
  end
end

--- Open (or focus) the sidebar for project, listing its pages.
function M.open(proj)
  project = proj
  ensure_hl()
  build_tabs()

  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, 'chatora://sidebar')
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

  if not (win and vim.api.nvim_win_is_valid(win)) then
    vim.cmd('topleft ' .. tostring(config.options.sidebar_width) .. 'vsplit')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  else
    vim.api.nvim_set_current_win(win)
  end

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = true
  vim.wo[win].winfixwidth = true
  -- Pin the window to its buffer: opening a file while the sidebar is
  -- focused must not hijack this window (E1513 instead).
  vim.wo[win].winfixbuf = true
  vim.wo[win].statusline = 'chatora: ' .. project
  apply_winbar()

  lsp.ensure_start(buf)
  M.reload()

  -- The filtered tabs need the user's saved pageFilters; fetch once, then let
  -- whichever tab is showing pick up its now-resolvable query.
  if not me then
    lsp.request_ok('chatora/authStatus', {}, function(result)
      me = result.user
      if me then
        M.load_more()
      end
    end)
  end
end

-- Keep the marks in sync with buffer modified state. BufModifiedSet alone is
-- not enough: it doesn't fire for API-driven buffer edits, so listen to
-- text-change events too (page.lua additionally reports state transitions
-- through chatora.status after open/save).
vim.api.nvim_create_autocmd({ 'BufModifiedSet', 'TextChanged', 'TextChangedI' }, {
  group = vim.api.nvim_create_augroup('ChatoraSidebar', { clear = true }),
  pattern = 'cosense://*',
  callback = function()
    vim.schedule(M.refresh_marks)
  end,
})

return M
