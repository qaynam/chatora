local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')
local page = require('chatora.page')
local search = require('chatora.search')

local buf, win
local project
local line_pages = {}

local winutil = require('chatora.winutil')

local function ensure_editor_win()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
  return winutil.ensure_editor_win({ exclude = win })
end

local function render(pages)
  line_pages = {}
  local lines = {}
  for i, p in ipairs(pages) do
    lines[i] = p.title or '(untitled)'
    line_pages[i] = p
  end
  if #lines == 0 then
    lines = { '(no pages)' }
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M.reload()
  if not project then
    return
  end
  lsp.request_ok('chatora/listPages', { project = project, limit = 100 }, function(result)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      return
    end
    render(result.pages or {})
  end)
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
  vim.wo[win].statusline = 'chatora: ' .. project

  lsp.ensure_start(buf)
  M.reload()
end

return M
