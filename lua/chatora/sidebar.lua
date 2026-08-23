-- Left sidebar listing a project's pages (infinite-scroll via
-- chatora/listPages), with unsaved-change (●) marks kept in sync with
-- buffer state.
local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')
local page = require('chatora.page')
local search = require('chatora.search')
local uri = require('chatora.uri')

local buf, win
local project
local line_pages = {}
local current_pages = {}
local ns = vim.api.nvim_create_namespace('chatora_sidebar')

local winutil = require('chatora.winutil')

local function ensure_editor_win()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
  return winutil.ensure_editor_win({ exclude = win })
end

--- Buffer names of loaded cosense pages with unsaved changes.
local function modified_uris()
  local set = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
      local name = vim.api.nvim_buf_get_name(b)
      if name:match('^cosense://') then
        set[name] = true
      end
    end
  end
  return set
end

local MARK = '● '

local function render(pages)
  current_pages = pages
  line_pages = {}
  local mods = modified_uris()
  local lines = {}
  local marked = {}
  for i, p in ipairs(pages) do
    local is_mod = (project and p.title and mods[uri.format(project, p.title)]) or false
    lines[i] = (is_mod and MARK or '  ') .. (p.title or '(untitled)')
    marked[i] = is_mod
    line_pages[i] = p
  end
  if #lines == 0 then
    lines = { '  (no pages)' }
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, is_mod in ipairs(marked) do
    if is_mod then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { end_col = #MARK, hl_group = 'DiagnosticWarn' })
    end
  end
  vim.bo[buf].modifiable = false
end

--- Re-render the unsaved (●) marks from cached pages, without refetching.
function M.refresh_marks()
  if buf and vim.api.nvim_buf_is_valid(buf) and current_pages then
    render(current_pages)
  end
end

local PAGE_SIZE = 100
local total_count = nil
local loading = false

--- Fetch the next batch (infinite scroll). Appends to current_pages.
function M.load_more()
  if not project or loading then
    return
  end
  if total_count and #current_pages >= total_count then
    return
  end
  loading = true
  local skip = #current_pages
  lsp.request_ok(
    'chatora/listPages',
    { project = project, skip = skip, limit = PAGE_SIZE },
    function(result)
      loading = false
      if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
      end
      total_count = result.count or total_count
      local fetched = result.pages or {}
      if skip == 0 then
        render(fetched)
      elseif #fetched > 0 then
        for _, p in ipairs(fetched) do
          current_pages[#current_pages + 1] = p
        end
        render(current_pages)
      else
        -- Server returned nothing: stop asking.
        total_count = #current_pages
      end
    end
  )
end

function M.reload()
  if not project then
    return
  end
  current_pages = {}
  total_count = nil
  loading = false
  M.load_more()
end

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
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', '<CR>', function() M.open_current() end, opts)
  vim.keymap.set('n', 'R', function() M.reload() end, opts)
  vim.keymap.set('n', 's', function() M.search() end, opts)
  vim.keymap.set('n', 'n', function() M.new_page() end, opts)
  vim.keymap.set('n', 'P', function() require('chatora').switch_project() end, opts)
  vim.keymap.set('n', 'q', function() M.close() end, opts)
end

--- Open (or focus) the sidebar for project, listing its pages.
function M.open(proj)
  project = proj

  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, 'chatora://sidebar')
    vim.bo[buf].buftype = 'nofile'
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

  lsp.ensure_start(buf)
  M.reload()
end

-- Keep the ● marks in sync with buffer modified state. BufModifiedSet alone
-- is not enough: it doesn't fire for API-driven buffer edits, so listen to
-- text-change events too (page.lua additionally calls refresh_marks after
-- open/save state transitions).
vim.api.nvim_create_autocmd({ 'BufModifiedSet', 'TextChanged', 'TextChangedI' }, {
  group = vim.api.nvim_create_augroup('ChatoraSidebar', { clear = true }),
  pattern = 'cosense://*',
  callback = function()
    vim.schedule(M.refresh_marks)
  end,
})

return M
