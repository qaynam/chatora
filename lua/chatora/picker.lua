-- Incremental search picker, laid out like telescope: the prompt sits on top of
-- the result list, with the selected page's text previewed alongside. Typing
-- re-queries chatora/search (debounced); an empty query shows recent pages.
--
-- Telescope users get the same search as a telescope picker instead; see
-- lua/telescope/_extensions/chatora.lua.
local M = {}

local lsp = require('chatora.lsp')
local search = require('chatora.search')
local winutil = require('chatora.winutil')

local uv = vim.uv or vim.loop

local DEBOUNCE_MS = 250
local PREVIEW_DEBOUNCE_MS = 80
local LIST_HEIGHT = 16
local LIST_RATIO = 0.4
local MAX_WIDTH = 140
-- Screen margin on each side, so the picker never touches the terminal edge.
local MARGIN = 4

M.ns = vim.api.nvim_create_namespace('chatora_picker')

local state = nil

local function ensure_hl()
  vim.api.nvim_set_hl(0, 'ChatoraPickerMatch', { link = 'Search', default = true })
end

local function close()
  local s = state
  if not s then
    return
  end
  state = nil
  for _, timer in ipairs({ s.timer, s.preview_timer }) do
    if timer then
      timer:stop()
      timer:close()
    end
  end
  vim.cmd('stopinsert')
  for _, w in ipairs({ s.preview_win, s.list_win, s.input_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  for _, b in ipairs({ s.preview_buf, s.list_buf, s.input_buf }) do
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  if s.prev_win and vim.api.nvim_win_is_valid(s.prev_win) then
    vim.api.nvim_set_current_win(s.prev_win)
  end
end

--- Name the preview pane after the page it is showing. Telescope puts the file
--- name on the border; doing the same keeps it off the first text line, where it
--- would run into the placeholder.
local function set_preview_title(title)
  local s = state
  if not (s and vim.api.nvim_win_is_valid(s.preview_win)) then
    return
  end
  local cfg = vim.api.nvim_win_get_config(s.preview_win)
  local room = math.max(4, (cfg.width or 20) - 4)
  local shown = (vim.fn.strdisplaywidth(title) > room)
      and (vim.fn.strcharpart(title, 0, room - 1) .. '…')
    or title
  cfg.title = ' ' .. shown .. ' '
  cfg.title_pos = 'center'
  pcall(vim.api.nvim_win_set_config, s.preview_win, cfg)
end

--- UTF-16 column -> byte column on `line`, or nil when it lands mid-character.
local function byte_col(line, char)
  local ok, col = pcall(vim.str_byteindex, line, 'utf-16', char, false)
  return ok and col or nil
end

--- Paint the page the way a real page buffer is painted, from the tokens and conceal
--- ranges `chatora/previewPage` ships with the text. No LSP attach and no treesitter, so
--- the cost does not scale with the size of the result list.
local function decorate_preview(bufnr, lines, decorations)
  for _, token in ipairs(decorations.tokens or {}) do
    local line = lines[token.line + 1]
    if line then
      local from = byte_col(line, token.char)
      local to = byte_col(line, token.char + token.length)
      if from and to then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, token.line, from, {
          end_col = to,
          hl_group = '@lsp.type.' .. token.type .. '.cosense',
        })
      end
    end
  end
  for _, range in ipairs(decorations.conceal or {}) do
    local line = lines[range.line + 1]
    if line then
      local from = byte_col(line, range.startChar)
      local to = byte_col(line, range.endChar)
      if from and to and to > from then
        local spec = range.notation and require('chatora.config').notation_spec(range.notation)
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, range.line, from, {
          end_col = to,
          conceal = spec and spec.icon or '',
        })
      end
    end
  end
  require('chatora.quote').render(bufnr, decorations.quotes or {})
end

local function render_preview(item, lines, decorations)
  local s = state
  if not (s and vim.api.nvim_buf_is_valid(s.preview_buf)) then
    return
  end
  set_preview_title(item and item.title or '')
  vim.bo[s.preview_buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.preview_buf, 0, -1, false, lines)
  vim.bo[s.preview_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(s.preview_buf, M.ns, 0, -1)
  if decorations then
    decorate_preview(s.preview_buf, lines, decorations)
  end

  if not vim.api.nvim_win_is_valid(s.preview_win) then
    return
  end
  local lnum, from, to = search.find_match(lines, item and item.words)
  if not lnum then
    pcall(vim.api.nvim_win_set_cursor, s.preview_win, { 1, 0 })
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, s.preview_buf, M.ns, lnum - 1, from, {
    end_col = to,
    hl_group = 'ChatoraPickerMatch',
  })
  pcall(vim.api.nvim_win_set_cursor, s.preview_win, { lnum, from })
  pcall(vim.api.nvim_win_call, s.preview_win, function()
    vim.cmd('normal! zz')
  end)
end

local function fetch_preview()
  local s = state
  if not s then
    return
  end
  local item = s.items[s.selected]
  if not item then
    render_preview(nil, {})
    return
  end
  local cached = s.preview_cache[item.title]
  if cached then
    render_preview(item, cached.lines, cached)
    return
  end

  render_preview(item, { '  読み込み中…' })
  local title = item.title
  lsp.request_ok('chatora/previewPage', { project = s.project, title = title }, function(result)
    if not (state and state.items[state.selected] and state.items[state.selected].title == title) then
      return
    end
    local page = {
      lines = vim.split(result.text or '', '\n', { plain = true }),
      tokens = result.tokens,
      conceal = result.conceal,
      quotes = result.quotes,
    }
    state.preview_cache[title] = page
    render_preview(state.items[state.selected], page.lines, page)
  end)
end

local function schedule_preview()
  local s = state
  if not s then
    return
  end
  s.preview_timer:stop()
  s.preview_timer:start(
    PREVIEW_DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      if state then
        fetch_preview()
      end
    end)
  )
end

local function render_list()
  local s = state
  if not (s and vim.api.nvim_buf_is_valid(s.list_buf)) then
    return
  end
  local lines = {}
  for i, item in ipairs(s.items) do
    lines[i] = item.label
  end
  if #lines == 0 then
    lines = { '  (no results)' }
  end
  vim.bo[s.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.list_buf, 0, -1, false, lines)
  vim.bo[s.list_buf].modifiable = false
  s.selected = math.min(math.max(s.selected, 1), math.max(#s.items, 1))
  if vim.api.nvim_win_is_valid(s.list_win) then
    vim.api.nvim_win_set_cursor(s.list_win, { s.selected, 0 })
  end
end

local function set_items(items)
  local s = state
  if not s then
    return
  end
  s.items = items
  s.selected = 1
  render_list()
  schedule_preview()
end

local function fetch(query)
  local s = state
  if not s then
    return
  end
  -- Bump the generation so a response for a since-superseded query (out of
  -- order due to network/debounce timing) is dropped instead of overwriting
  -- fresher results.
  s.gen = s.gen + 1
  local gen = s.gen

  if query == '' then
    lsp.request_ok('chatora/listPages', { project = s.project, limit = 30 }, function(result)
      if not (state and state.gen == gen) then
        return
      end
      local items = {}
      for _, p in ipairs(result.pages or {}) do
        if p.title then
          items[#items + 1] = { title = p.title, label = '  ' .. p.title }
        end
      end
      set_items(items)
    end)
    return
  end

  lsp.request_ok('chatora/search', { project = s.project, query = query }, function(result)
    if not (state and state.gen == gen) then
      return
    end
    local items = {}
    for _, p in ipairs(result.pages or {}) do
      if p.title then
        local snippet = search.snippet(p)
        items[#items + 1] = {
          title = p.title,
          label = '  ' .. p.title .. (snippet ~= '' and ('  — ' .. snippet) or ''),
          words = search.match_words(p, query),
        }
      end
    end
    set_items(items)
  end)
end

local function current_query()
  local s = state
  if not (s and vim.api.nvim_buf_is_valid(s.input_buf)) then
    return ''
  end
  return vim.api.nvim_buf_get_lines(s.input_buf, 0, 1, false)[1] or ''
end

local function on_input_changed()
  local s = state
  if not s then
    return
  end
  s.timer:stop()
  s.timer:start(
    DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      if state then
        fetch(current_query())
      end
    end)
  )
end

function M.move(delta)
  local s = state
  if not (s and #s.items > 0) then
    return
  end
  s.selected = ((s.selected - 1 + delta) % #s.items) + 1
  if vim.api.nvim_win_is_valid(s.list_win) then
    vim.api.nvim_win_set_cursor(s.list_win, { s.selected, 0 })
  end
  schedule_preview()
end

function M.accept()
  local s = state
  if not s then
    return
  end
  local item = s.items[s.selected]
  close()
  if item and item.title then
    local target = winutil.ensure_editor_win()
    require('chatora.page').open(s.project, item.title, target)
  end
end

function M.close()
  close()
end

--- Move the cursor into the preview pane, where ordinary normal-mode motions read the
--- page. Telescope cannot do this: its previewer window is not focusable.
function M.focus_preview()
  local s = state
  if not (s and vim.api.nvim_win_is_valid(s.preview_win)) then
    return
  end
  vim.cmd('stopinsert')
  vim.api.nvim_set_current_win(s.preview_win)
end

--- Return from the preview to the prompt, resuming the query where it left off.
function M.focus_prompt()
  local s = state
  if not (s and vim.api.nvim_win_is_valid(s.input_win)) then
    return
  end
  vim.api.nvim_set_current_win(s.input_win)
  vim.cmd('startinsert!')
end

function M.is_open()
  return state ~= nil
end

function M.get_items()
  return state and state.items or nil
end

function M.get_preview()
  local s = state
  if not (s and vim.api.nvim_buf_is_valid(s.preview_buf)) then
    return nil
  end
  return vim.api.nvim_buf_get_lines(s.preview_buf, 0, -1, false)
end

function M.get_preview_marks()
  local s = state
  if not (s and vim.api.nvim_buf_is_valid(s.preview_buf)) then
    return nil
  end
  return vim.api.nvim_buf_get_extmarks(s.preview_buf, M.ns, 0, -1, { details = true })
end

--- Replace the query and fetch immediately, bypassing the debounce.
function M.set_query(q)
  local s = state
  if not (s and vim.api.nvim_buf_is_valid(s.input_buf)) then
    return
  end
  vim.api.nvim_buf_set_lines(s.input_buf, 0, -1, false, { q })
  fetch(q)
end

-- Screen rows a bordered box adds around its content.
local BORDER_ROWS = 2
local PROMPT_ROWS = 1 + BORDER_ROWS

--- Geometry of the three panes, centred on the editor.
local function layout()
  local width = math.min(MAX_WIDTH, math.max(40, vim.o.columns - MARGIN * 2))
  local list_height = math.min(LIST_HEIGHT, math.max(6, vim.o.lines - PROMPT_ROWS - 5))
  -- Each pane's border costs a cell on both sides.
  local list_width = math.max(20, math.floor((width - 4) * LIST_RATIO))
  local preview_width = math.max(20, width - 4 - list_width)
  local total_rows = PROMPT_ROWS + list_height + BORDER_ROWS
  return {
    list_width = list_width,
    list_height = list_height,
    preview_width = preview_width,
    -- Reaches from the prompt's top border down to the list's bottom border.
    preview_height = total_rows - BORDER_ROWS,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.max(0, math.floor((vim.o.lines - total_rows) / 2)),
  }
end

local function scratch_buf(modifiable)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = modifiable
  return buf
end

function M.open(project, initial_query)
  close()
  ensure_hl()

  local prev_win = vim.api.nvim_get_current_win()
  local geom = layout()

  local input_buf = scratch_buf(true)
  local list_buf = scratch_buf(false)
  local preview_buf = scratch_buf(false)

  local list_win = vim.api.nvim_open_win(list_buf, false, {
    relative = 'editor',
    width = geom.list_width,
    height = geom.list_height,
    row = geom.row + PROMPT_ROWS,
    col = geom.col,
    style = 'minimal',
    border = 'rounded',
    title = ' Results ',
    title_pos = 'center',
  })
  vim.wo[list_win].cursorline = true
  -- One row per result: a wrapped label would break the row-to-item mapping the
  -- cursor uses, and the title (the part that matters) leads the label anyway.
  vim.wo[list_win].wrap = false

  local preview_win = vim.api.nvim_open_win(preview_buf, false, {
    relative = 'editor',
    width = geom.preview_width,
    height = geom.preview_height,
    row = geom.row,
    col = geom.col + geom.list_width + BORDER_ROWS,
    style = 'minimal',
    border = 'rounded',
  })
  vim.wo[preview_win].wrap = false
  -- Same contract as a page window: markup hidden, revealed on the cursor line.
  vim.wo[preview_win].conceallevel = 2
  vim.wo[preview_win].concealcursor = ''

  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = 'editor',
    width = geom.list_width,
    height = 1,
    row = geom.row,
    col = geom.col,
    style = 'minimal',
    border = 'rounded',
    title = ' ' .. project .. ' ',
    title_pos = 'center',
  })

  state = {
    project = project,
    input_buf = input_buf,
    input_win = input_win,
    list_buf = list_buf,
    list_win = list_win,
    preview_buf = preview_buf,
    preview_win = preview_win,
    preview_cache = {},
    prev_win = prev_win,
    items = {},
    selected = 1,
    gen = 0,
    timer = uv.new_timer(),
    preview_timer = uv.new_timer(),
  }

  local function map(modes, key, fn)
    vim.keymap.set(modes, key, fn, { buffer = input_buf, nowait = true, silent = true })
  end
  local function next_item()
    M.move(1)
  end
  local function prev_item()
    M.move(-1)
  end
  map({ 'i', 'n' }, '<CR>', M.accept)
  map({ 'i', 'n' }, '<C-n>', next_item)
  map({ 'i', 'n' }, '<C-p>', prev_item)
  map({ 'i', 'n' }, '<Down>', next_item)
  map({ 'i', 'n' }, '<Up>', prev_item)
  local function scroll_preview(keys)
    pcall(vim.api.nvim_win_call, preview_win, function()
      vim.cmd('normal! ' .. math.floor(geom.preview_height / 2) .. keys)
    end)
  end
  map({ 'i', 'n' }, '<C-d>', function()
    scroll_preview('\x05')
  end)
  map({ 'i', 'n' }, '<C-u>', function()
    scroll_preview('\x19')
  end)
  -- telescope-style modal prompt: <Esc> in insert drops to normal mode, where
  -- the query line is a normal buffer (vim motions / visual mode / edits all
  -- work); j/k move the selection, <Esc>/q close, <C-c> closes from any mode.
  map('i', '<Esc>', function()
    vim.cmd('stopinsert')
  end)
  map('n', 'j', next_item)
  map('n', 'k', prev_item)
  map('n', '<Esc>', close)
  map('n', 'q', close)
  map({ 'i', 'n' }, '<C-c>', close)

  -- Reading a long page needs more than half-page scrolling, so the preview can be
  -- entered outright: every normal-mode motion works in there, and <Esc>/q hands the
  -- prompt back. (Telescope cannot do this — its previewer window is not focusable.)
  map({ 'i', 'n' }, '<C-f>', M.focus_preview)
  for _, key in ipairs({ '<Esc>', 'q', '<C-f>' }) do
    vim.keymap.set('n', key, M.focus_prompt, { buffer = preview_buf, nowait = true, silent = true })
  end
  vim.keymap.set('n', '<CR>', M.accept, { buffer = preview_buf, nowait = true, silent = true })

  -- Close when focus leaves the picker entirely; moving between its own panes is fine.
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = input_buf,
    callback = function()
      vim.schedule(function()
        if state and not vim.tbl_contains({ state.list_win, state.preview_win }, vim.api.nvim_get_current_win()) then
          close()
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = preview_buf,
    callback = function()
      vim.schedule(function()
        if state and not vim.tbl_contains({ state.list_win, state.input_win }, vim.api.nvim_get_current_win()) then
          close()
        end
      end)
    end,
  })

  vim.api.nvim_buf_attach(input_buf, false, {
    on_lines = function()
      vim.schedule(on_input_changed)
    end,
  })

  if initial_query and initial_query ~= '' then
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { initial_query })
    vim.api.nvim_win_set_cursor(input_win, { 1, #initial_query })
  end
  fetch(initial_query or '')
  vim.cmd('startinsert!')
end

return M
