-- Related-pages side panel: a fixed bottom split listing 1-hop/2-hop links
-- for the current page, refreshed whenever a page buffer is (re)loaded.
local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')

local buf, win, parent_win
local cur_project, cur_title
local line_items = {}
local ns = vim.api.nvim_create_namespace('chatora_related')

-- Cosense's own word for a page's incoming links, so the panel and the page-info
-- float name the same number the same way.
local LINKED_LABEL = '被リンク '

local function ensure_hl()
  vim.api.nvim_set_hl(0, 'ChatoraRelatedHeader', { bold = true, underline = true, default = true })
  vim.api.nvim_set_hl(0, 'ChatoraRelatedEmpty', { link = 'NonText', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraRelatedCount', { link = 'Comment', default = true })
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

--- Options and mappings of the panel buffer.
local function configure_buf()
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

--- The panel's buffer, created on first open and configured again whenever it was
--- unloaded: `:bdelete` keeps the buffer — and its name, so a replacement carrying the same
--- one fails with E95 — but drops its options and its buffer-local mappings.
local function ensure_buf()
  local exists = buf ~= nil and vim.api.nvim_buf_is_valid(buf)
  if exists and vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  if not exists then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, 'chatora://related')
  end
  configure_buf()
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
    items = items or {}
    lines[#lines + 1] = #items > 0 and (name .. '  (' .. #items .. ')') or name
    header_lines[#header_lines + 1] = #lines - 1
    if #items == 0 then
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
  -- Rendering marks an acwrite buffer modified, which makes Neovim offer to save it on
  -- exit. This is a view; there is nothing to save.
  vim.bo[buf].modified = false
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

-- Which edge the panel takes. A bottom strip suits a page you are reading through; a tall
-- column on the right suits one with many links, and neither is right for everyone.
local side_override = nil

--- 'bottom' or 'right'.
function M.side()
  return side_override or (config.options.related_position == 'right' and 'right' or 'bottom')
end

--- Move the panel to the other edge, reopening it there when it is on screen. The choice
--- outlives the panel but not the session; `related_position` is what makes it stick.
function M.flip()
  side_override = M.side() == 'right' and 'bottom' or 'right'
  if is_open() then
    M.close()
    M.open()
  end
  vim.notify('[chatora] 関連ページ: ' .. (M.side() == 'right' and '右' or '下'))
end

--- Every window showing the panel buffer. More than one means a previous open leaked, so
--- close() has something to sweep: the panel is one window by construction.
local function panel_wins()
  local found = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if buf and vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
      found[#found + 1] = w
    end
  end
  return found
end

function M.open()
  ensure_buf()
  -- Idempotent: auto-open and an explicit toggle can both fire for one page, and splitting
  -- again would leave a second panel that nothing tracks and nothing closes.
  if is_open() then
    if cur_project and cur_title then
      M.refresh(cur_project, cur_title)
    end
    return
  end
  local cur = vim.api.nvim_get_current_win()
  if is_plugin_win(cur) then
    cur = find_editor_win() or cur
    vim.api.nvim_set_current_win(cur)
  end
  parent_win = cur

  if M.side() == 'right' then
    vim.cmd('botright ' .. tostring(config.options.related_width) .. 'vsplit')
  else
    vim.cmd('belowright ' .. tostring(config.options.related_height) .. 'split')
  end
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = true
  -- Pin the dimension the panel owns, so a later split resizes the page instead of it.
  vim.wo[win].winfixheight = M.side() == 'bottom'
  vim.wo[win].winfixwidth = M.side() == 'right'
  -- Same as the sidebar: never let another buffer take over this window.
  vim.wo[win].winfixbuf = true
  -- Label + panel background so the split is visibly chrome, not page content.
  vim.wo[win].winbar = '%#ChatoraRelatedTitle# 関連ページ%*%#ChatoraRelatedCount#%{%v:lua.require("chatora.related").winbar_count()%}%*'
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
  -- Closes every window showing the panel, not just the tracked one: an older build could
  -- leak a second, and leaving it behind makes the panel look like it moved on its own.
  for _, w in ipairs(panel_wins()) do
    pcall(vim.api.nvim_win_close, w, true)
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

--- The subject page's own incoming-link count, for the winbar. Empty until that page's
--- metadata has arrived, so the label never shows an invented number.
function M.winbar_count()
  if not (cur_project and cur_title) then
    return ''
  end
  local bufnr = vim.fn.bufnr(require('chatora.uri').format(cur_project, cur_title))
  if bufnr == -1 then
    return ''
  end
  local meta = require('chatora.page').meta(bufnr)
  if not (meta and meta.linked > 0) then
    return ''
  end
  return '  ' .. LINKED_LABEL .. meta.linked
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
