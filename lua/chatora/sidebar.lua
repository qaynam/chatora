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
  local configured = config.options.sidebar_separator
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
  { label = 'すべて' },
  { label = '未読', filter = 'me', unread_only = true },
}

-- What a `sidebar_tabs` entry, or a folder in one, may say. A key outside this list is a
-- typo the reader would otherwise only notice as a tab that lists everything.
local LIST_KEYS = {
  label = true,
  name = true,
  icon = true,
  filter = true,
  related = true,
  pages = true,
  unread = true,
  unread_only = true,
  open = true,
}
local TAB_KEYS = vim.tbl_extend('force', LIST_KEYS, { folders = true })

local FOLDER_OPEN = '▾ '
local FOLDER_CLOSED = '▸ '

local tabs = {}
local active = 1

--- Each project's tabs, kept while the session lasts so coming back to one shows its list
--- at once. A list is a few hundred rows of ids and titles — far cheaper to hold than the
--- requests that would rebuild it, and the poll loop brings whichever is on screen up to
--- date anyway.
local sessions = {}

-- Fetched once per session; a `filter = 'me'` tab cannot query until it lands.
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

--- One list from its spec: a tab, or a folder inside one. `prior` is the list that stood
--- at the same position before a rebuild; its pages are carried over only under the same
--- label, since a reordered or renamed list is a different query.
local function make_list(spec, keys, where, fallback_label, prior)
  for key in pairs(spec) do
    if not keys[key] then
      vim.notify_once(
        ('[chatora] %sに知らないキー `%s` があります（使えるのは label, icon, filter, related, pages, unread%s）'):format(
          where,
          key,
          keys.folders and ', folders' or ', open'
        ),
        vim.log.levels.WARN
      )
    end
  end
  if spec.pages ~= nil and type(spec.pages) ~= 'function' then
    vim.notify_once(('[chatora] %sの pages は関数にしてください'):format(where), vim.log.levels.WARN)
  end
  if spec.related ~= nil and type(spec.related) ~= 'string' and type(spec.related) ~= 'table' then
    vim.notify_once(
      ('[chatora] %sの related はページのタイトルか、その並びにしてください'):format(where),
      vim.log.levels.WARN
    )
  end
  local label = spec.label or spec.name or fallback_label
  local carried = prior ~= nil and prior.label == label and prior or nil
  return {
    label = label,
    icon = spec.icon,
    filter = spec.filter,
    related = (type(spec.related) == 'string' or type(spec.related) == 'table') and spec.related or nil,
    pages = type(spec.pages) == 'function' and spec.pages or nil,
    unread_only = (spec.unread_only or spec.unread) and true or nil,
    state = carried and carried.state or new_state(),
    carried = carried,
  }
end

--- Rebuild the tab list from config, carrying each tab's already-fetched pages over.
--- Closing and reopening the sidebar must not cost a full refetch — the poll loop is what
--- keeps the list current.
---
--- @param keep_state boolean False when the project changed: another project's list is
---   not this one's.
local function build_tabs(keep_state)
  local specs = config.options.sidebar_tabs
  if specs == false then
    specs = { DEFAULT_TABS[1] }
  elseif type(specs) ~= 'table' or #specs == 0 then
    specs = DEFAULT_TABS
  end
  local previous = tabs
  tabs = {}
  for i, spec in ipairs(specs) do
    local prior = keep_state and previous[i] or nil
    local tab = make_list(spec, TAB_KEYS, ('sidebar_tabs の %d 番目'):format(i), '#' .. i, prior)
    if type(spec.folders) == 'table' then
      tab.folders = {}
      for j, fspec in ipairs(spec.folders) do
        local prior_folder = prior and prior.folders and prior.folders[j] or nil
        local folder = make_list(
          fspec,
          LIST_KEYS,
          ('sidebar_tabs の %d 番目のフォルダー %d'):format(i, j),
          '#' .. j,
          prior_folder
        )
        -- Whether the reader left it open outlives a rebuild; the spec only says how it starts.
        folder.open = folder.carried and folder.carried.open or (not folder.carried and fspec.open ~= false)
        folder.carried = nil
        tab.folders[j] = folder
      end
    end
    tab.carried = nil
    tabs[i] = tab
  end
  if active > #tabs then
    active = 1
  end
end

--- The lists a tab draws: its open folders, or the tab itself.
local function visible_lists(tab)
  if not tab.folders then
    return { tab }
  end
  return vim.tbl_filter(function(folder)
    return folder.open
  end, tab.folders)
end

--- Every list a tab holds, open or not.
local function all_lists(tab)
  return tab.folders or { tab }
end

--- The `filterType`/`filterValue` pair for a tab, or nil for "no filter".
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
    local text = (tab.icon and (tab.icon .. ' ') or '') .. tab.label
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
  for _, list in ipairs(tab and is_open() and visible_lists(tab) or {}) do
    if not list.state.fetched and #list.state.pages == 0 then
      waiting = true
    end
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
  local separators = config.options.sidebar_separator ~= false
  local tab = tabs[active]
  line_pages, line_folders = {}, {}
  local lines = {}
  local rows = {}
  local function add_page(p)
    local unread = is_unread(p)
    local icon, hl_group = status_of(p)
    -- Cosense sorts pinned pages to the front; the mark says why they are there.
    local pinned = type(p.pin) == 'number' and p.pin > 0
    local prefix = (unread and UNREAD_BAR or READ_BAR) .. (pinned and PIN_MARK or '')
    lines[#lines + 1] = prefix .. (p.title or '(untitled)')
    rows[#rows + 1] = { unread = unread, icon = icon, hl_group = hl_group, pin_width = pinned and #PIN_MARK or 0 }
    line_pages[#lines] = p
  end
  local function add_note(state, indent)
    lines[#lines + 1] = indent .. (state.fetched and '(該当なし)' or (spinner.frame() .. ' 読み込み中…'))
    rows[#rows + 1] = { note = true }
  end
  if tab and tab.folders then
    for _, folder in ipairs(tab.folders) do
      lines[#lines + 1] = (folder.open and FOLDER_OPEN or FOLDER_CLOSED)
        .. (folder.icon and (folder.icon .. ' ') or '')
        .. folder.label
      rows[#rows + 1] = { folder = true }
      line_folders[#lines] = folder
      if folder.open then
        for _, p in ipairs(folder.state.pages) do
          add_page(p)
        end
        if #folder.state.pages == 0 then
          add_note(folder.state, '  ')
        end
      end
    end
    if #lines == 0 then
      lines = { ' (フォルダーがありません)' }
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

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, row_info in ipairs(rows) do
    local row = i - 1
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
        vim.api.nvim_buf_set_extmark(buf, ns, row, #UNREAD_BAR, {
          end_col = #UNREAD_BAR + row_info.pin_width,
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
  vim.bo[buf].modifiable = false
  -- Rendering marks an acwrite buffer modified, which makes Neovim offer to save it on
  -- exit. This is a view; there is nothing to save.
  vim.bo[buf].modified = false
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

--- Request params for one batch of `tab`, or nil when it cannot query yet.
local function batch_params(tab, skip)
  local filter_type, filter_value = filter_of(tab)
  if tab.filter == 'me' and not filter_type then
    return nil
  end
  return {
    project = project,
    skip = skip,
    limit = PAGE_SIZE,
    unreadOnly = tab.unread_only or nil,
    filterType = filter_type,
    filterValue = filter_value,
  }
end

--- A tab whose list comes whole rather than in batches: the related pages of a title, or
--- whatever the reader's `pages` function hands over.
local function comes_whole(tab)
  return tab.related ~= nil or tab.pages ~= nil
end

--- Only rows the renderer can draw: a title each, in the order given.
local function as_rows(list)
  local rows = {}
  for _, entry in ipairs(type(list) == 'table' and list or {}) do
    if type(entry) == 'string' then
      rows[#rows + 1] = { title = entry }
    elseif type(entry) == 'table' and entry.title then
      rows[#rows + 1] = entry
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
    local function settle(list, why)
      if list == nil then
        cb(nil, why or 'pages が一覧を返しませんでした')
      else
        cb(as_rows(list))
      end
    end
    -- A list handed to `done` from inside the function waits until the function has
    -- returned: what happens to the list (drawing it) must not be caught as the function's
    -- own error, and a second `done` must not count.
    local finished, returned, held = false, false, nil
    local function done(list, why)
      if finished then
        return
      end
      finished = true
      if returned then
        settle(list, why)
      else
        held = { list, why }
      end
    end
    local ok, ret = xpcall(function()
      return tab.pages({ project = project }, done)
    end, function(e)
      -- Where it broke, since an error out of a C function (table.sort, say) names no line.
      return debug.traceback(tostring(e), 2)
    end)
    returned = true
    if not ok then
      done(nil, 'pages: ' .. tostring(ret))
    elseif ret ~= nil then
      done(ret)
    end
    if held then
      settle(held[1], held[2])
    end
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
      if not state.exhausted and #state.pages < MIN_ROWS then
        load_list(list, index)
      end
    end
  end)
end

--- Fetch what the active tab is missing (infinite scroll). In a tab of folders that is
--- every open folder still without its first batch; once they all have one, the scroll
--- reaching the bottom extends the last open folder, which is what the bottom belongs to.
function M.load_more()
  local index = active
  local tab = tabs[index]
  if not (project and tab) then
    return
  end
  if not tab.folders then
    load_list(tab, index)
    return
  end
  local pending = false
  for _, folder in ipairs(tab.folders) do
    if folder.open and not folder.state.fetched then
      load_list(folder, index)
      pending = true
    end
  end
  if pending then
    return
  end
  for j = #tab.folders, 1, -1 do
    if tab.folders[j].open then
      load_list(tab.folders[j], index)
      return
    end
  end
end

--- Pin one more tab, as an entry at the end of `sidebar_tabs` would.
function M.add_tab(spec)
  local specs = config.options.sidebar_tabs
  if specs == false then
    specs = { DEFAULT_TABS[1] }
  elseif type(specs) ~= 'table' or #specs == 0 then
    specs = vim.deepcopy(DEFAULT_TABS)
  end
  specs[#specs + 1] = spec
  config.options.sidebar_tabs = specs
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
  for _, tab in ipairs(tabs) do
    for _, list in ipairs(all_lists(tab)) do
      list.state = new_state()
    end
    tab.state = new_state()
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
  local seconds = config.options.sidebar_poll
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
    vim.cmd('topleft ' .. tostring(config.options.sidebar_width) .. 'vsplit')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
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
  apply_statusline()
  apply_winbar()

  lsp.ensure_start(buf)
  -- Reopening shows what is already loaded; the poll loop below brings it up to date in
  -- the background. Only a first open (or a project switch) has nothing to show.
  if #tabs > 0 and #tabs[active].state.pages > 0 then
    render()
    restore_cursor()
  else
    M.reload()
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
          if list.filter == 'me' then
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
    -- New pages and searches belong to the project in front of them, not to whichever one
    -- the session started on.
    require('chatora').session.project = proj
  end,
})

return M
