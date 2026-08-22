local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')

local buf, win, parent_win
local cur_project, cur_title
local line_items = {}

local function is_open()
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local winutil = require('chatora.winutil')
local is_plugin_win = winutil.is_plugin_win
local find_editor_win = winutil.find_editor_win

local function ensure_buf()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, 'chatora://related')
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'chatora_related'

  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set('n', '<CR>', function() M.open_current() end, opts)
  vim.keymap.set('n', 'q', function() M.close() end, opts)
end

local function render(links1hop, links2hop)
  line_items = {}
  local lines = {}

  local function add_section(name, items)
    lines[#lines + 1] = '# ' .. name
    if not items or #items == 0 then
      lines[#lines + 1] = '  (none)'
    else
      for _, item in ipairs(items) do
        lines[#lines + 1] = item.title or '(untitled)'
        line_items[#lines] = item
      end
    end
  end

  add_section('1-hop', links1hop)
  lines[#lines + 1] = ''
  add_section('2-hop', links2hop)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

--- Refresh the panel contents for project/title. No-op (besides remembering
--- the target) when the panel is closed.
function M.refresh(project, title)
  cur_project, cur_title = project, title
  if not is_open() then
    return
  end
  lsp.request_ok('chatora/relatedPages', { project = project, title = title }, function(result)
    if not is_open() then
      return
    end
    render(result.links1hop, result.links2hop)
  end)
end

--- Called by page.lua whenever a page buffer is (re)loaded. Refreshes the
--- panel if it's currently open; otherwise just remembers the target page.
function M.on_page_opened(project, title)
  if is_open() then
    M.refresh(project, title)
  else
    cur_project, cur_title = project, title
  end
end

function M.open()
  ensure_buf()
  local cur = vim.api.nvim_get_current_win()
  if is_plugin_win(cur) then
    cur = find_editor_win() or cur
    vim.api.nvim_set_current_win(cur)
  end
  parent_win = cur

  vim.cmd('belowright ' .. tostring(config.options.related_height) .. 'split')
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = true
  vim.wo[win].winfixheight = true

  if vim.api.nvim_win_is_valid(parent_win) then
    vim.api.nvim_set_current_win(parent_win)
  end

  if cur_project and cur_title then
    M.refresh(cur_project, cur_title)
  end
end

function M.close()
  if is_open() then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
end

function M.toggle()
  if is_open() then
    M.close()
  else
    M.open()
  end
end

function M.open_current()
  if not is_open() then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(win)[1]
  local item = line_items[lnum]
  if not item or not item.title then
    return
  end

  local target = parent_win
  if not (target and vim.api.nvim_win_is_valid(target)) then
    target = find_editor_win()
  end

  require('chatora.page').open(cur_project, item.title, target)
end

return M
