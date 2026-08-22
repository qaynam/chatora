-- Incremental search picker: a floating prompt + result list. Typing
-- re-queries chatora/search (debounced); an empty query shows recent pages.
-- <CR> opens the selection, <C-n>/<C-p>/<Down>/<Up> move, <Esc>/<C-c> close.
local M = {}

local lsp = require('chatora.lsp')
local winutil = require('chatora.winutil')

local uv = vim.uv or vim.loop

local DEBOUNCE_MS = 250
local LIST_HEIGHT = 12

local state = nil

local function close()
  local s = state
  if not s then
    return
  end
  state = nil
  if s.timer then
    s.timer:stop()
    s.timer:close()
  end
  vim.cmd('stopinsert')
  for _, w in ipairs({ s.list_win, s.input_win }) do
    if w and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  for _, b in ipairs({ s.list_buf, s.input_buf }) do
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  if s.prev_win and vim.api.nvim_win_is_valid(s.prev_win) then
    vim.api.nvim_set_current_win(s.prev_win)
  end
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
        local snippet = ''
        if p.lines and #p.lines > 0 then
          snippet = p.lines[2] or p.lines[1] or ''
        end
        local label = '  ' .. p.title
        if snippet ~= '' then
          label = label .. '  — ' .. snippet
        end
        items[#items + 1] = { title = p.title, label = label }
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

function M.is_open()
  return state ~= nil
end

--- Current result items (mainly for tests).
function M.get_items()
  return state and state.items or nil
end

--- Replace the query and fetch immediately, bypassing the debounce (tests).
function M.set_query(q)
  local s = state
  if not (s and vim.api.nvim_buf_is_valid(s.input_buf)) then
    return
  end
  vim.api.nvim_buf_set_lines(s.input_buf, 0, -1, false, { q })
  fetch(q)
end

--- Open the picker for project; initial_query (optional) pre-fills the prompt.
function M.open(project, initial_query)
  close()

  local prev_win = vim.api.nvim_get_current_win()
  local width = math.min(70, vim.o.columns - 8)
  local total_height = LIST_HEIGHT + 4 -- rough total incl. input + borders, for vertical centering only
  local row = math.max(1, math.floor((vim.o.lines - total_height) / 2))
  local col = math.floor((vim.o.columns - width) / 2)

  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[input_buf].buftype = 'nofile'
  vim.bo[input_buf].bufhidden = 'wipe'
  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[list_buf].buftype = 'nofile'
  vim.bo[list_buf].bufhidden = 'wipe'
  vim.bo[list_buf].modifiable = false

  local list_win = vim.api.nvim_open_win(list_buf, false, {
    relative = 'editor',
    width = width,
    height = LIST_HEIGHT,
    row = row + 3,
    col = col,
    style = 'minimal',
    border = 'rounded',
  })
  vim.wo[list_win].cursorline = true

  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = 'editor',
    width = width,
    height = 1,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' chatora search (' .. project .. ') ',
    title_pos = 'center',
  })

  state = {
    project = project,
    input_buf = input_buf,
    input_win = input_win,
    list_buf = list_buf,
    list_win = list_win,
    prev_win = prev_win,
    items = {},
    selected = 1,
    gen = 0,
    timer = uv.new_timer(),
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

  -- Close if the user clicks/jumps away from the prompt.
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = input_buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if state and vim.api.nvim_get_current_win() ~= state.list_win then
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
