-- Related-pages side panel: a fixed bottom split listing 1-hop/2-hop links
-- for the current page, refreshed whenever a page buffer is (re)loaded.
local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')

local buf, win, parent_win
local cur_project, cur_title
local line_items = {}
local ns = vim.api.nvim_create_namespace('chatora_related')

local function ensure_hl()
  vim.api.nvim_set_hl(0, 'ChatoraRelatedHeader', { bold = true, underline = true, default = true })
  vim.api.nvim_set_hl(0, 'ChatoraRelatedEmpty', { link = 'NonText', default = true })
  -- The panel gets the float background so it reads as chrome, not as a
  -- continuation of the page. Overridable like every Chatora* group.
  vim.api.nvim_set_hl(0, 'ChatoraRelatedNormal', { link = 'NormalFloat', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraRelatedTitle', { link = 'Title', default = true })
end

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
  -- acwrite (with page.lua's no-op chatora://* BufWriteCmd) so a reflexive
  -- :wq closes the window instead of E382.
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'chatora_related'

  local opts = { buffer = buf, nowait = true, silent = true, desc = 'chatora: 関連ページを開く' }
  vim.keymap.set('n', '<CR>', function() M.open_current() end, opts)
  vim.keymap.set('n', 'q', function()
    M.close({ by_user = true })
  end, { buffer = buf, nowait = true, silent = true, desc = 'chatora: 関連ページパネルを閉じる' })
end

--- Run `fn` with the panel's cursor and top line restored afterwards, so a
--- refresh triggered while reading the list doesn't scroll it back to the top.
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

local function render(links1hop, links2hop)
  ensure_hl()
  line_items = {}
  local lines = {}
  local header_lines = {}
  local empty_lines = {}

  local function add_section(name, items)
    lines[#lines + 1] = name
    header_lines[#header_lines + 1] = #lines - 1
    if not items or #items == 0 then
      lines[#lines + 1] = '  (none)'
      empty_lines[#empty_lines + 1] = #lines - 1
    else
      for _, item in ipairs(items) do
        lines[#lines + 1] = '  ' .. (item.title or '(untitled)')
        line_items[#lines] = item
      end
    end
  end

  add_section('1-hop', links1hop)
  lines[#lines + 1] = ''
  add_section('2-hop', links2hop)

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, l in ipairs(header_lines) do
    vim.api.nvim_buf_set_extmark(buf, ns, l, 0, {
      end_col = #lines[l + 1],
      hl_group = 'ChatoraRelatedHeader',
    })
  end
  for _, l in ipairs(empty_lines) do
    vim.api.nvim_buf_set_extmark(buf, ns, l, 0, {
      end_col = #lines[l + 1],
      hl_group = 'ChatoraRelatedEmpty',
    })
  end
  vim.bo[buf].modifiable = false
end

--- Refresh the panel contents for project/title. No-op (besides remembering
--- the target) when the panel is closed. A reply that arrives after the user
--- has moved to another page is dropped rather than shown against it.
function M.refresh(project, title)
  cur_project, cur_title = project, title
  if not is_open() then
    return
  end
  lsp.request_ok('chatora/relatedPages', { project = project, title = title }, function(result)
    if not is_open() or cur_project ~= project or cur_title ~= title then
      return
    end
    keeping_view(function()
      render(result.links1hop, result.links2hop)
    end)
  end)
end

-- Set when the user closes the panel with q: related_auto_open must not fight
-- an explicit close, so auto-open stays off until the next manual toggle.
local user_closed = false

--- Notify the panel that a page was (re)loaded: refreshes it if currently
--- open, opens it first when related_auto_open is on, otherwise just
--- remembers the target page for next time it opens.
function M.on_page_opened(project, title)
  cur_project, cur_title = project, title
  if is_open() then
    M.refresh(project, title)
    return
  end
  if config.options.related_auto_open and not user_closed then
    M.open()
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
  -- Same as the sidebar: never let another buffer take over this window.
  vim.wo[win].winfixbuf = true
  -- Label + panel background so the split is visibly chrome, not page content.
  vim.wo[win].winbar = '%#ChatoraRelatedTitle# 関連ページ%*'
  vim.wo[win].winhighlight = 'Normal:ChatoraRelatedNormal,EndOfBuffer:ChatoraRelatedNormal'
  user_closed = false

  if vim.api.nvim_win_is_valid(parent_win) then
    vim.api.nvim_set_current_win(parent_win)
  end

  if cur_project and cur_title then
    M.refresh(cur_project, cur_title)
  end
end

function M.close(opts)
  if is_open() then
    vim.api.nvim_win_close(win, true)
  end
  win = nil
  if opts and opts.by_user then
    user_closed = true
  end
end

function M.toggle()
  if is_open() then
    M.close({ by_user = true })
  else
    M.open()
  end
end

-- BufReadCmd only fires the first time a page is loaded, so switching back to
-- an already-open page buffer would otherwise leave the panel showing the
-- previous page's links.
vim.api.nvim_create_autocmd('BufEnter', {
  group = vim.api.nvim_create_augroup('ChatoraRelated', { clear = true }),
  pattern = 'cosense://*',
  callback = function(ev)
    local project, title = require('chatora.uri').parse(vim.api.nvim_buf_get_name(ev.buf))
    if project and title and (project ~= cur_project or title ~= cur_title) then
      M.on_page_opened(project, title)
    end
  end,
})

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
