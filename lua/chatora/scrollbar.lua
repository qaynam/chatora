-- A minimap of the page down the right edge of the window: where the changed lines are in
-- the *whole* page, and where in it the reader currently is. The telomere in the sign column
-- can only speak for the lines on screen; this is what says there is something worth
-- scrolling to. Cosense draws the same thing over its browser scrollbar
-- (`.scroll-bar-overlay .unread-bar`).
--
-- Drawn in a one-cell floating window rather than as virtual text on the page's own lines,
-- because a mark's row is a position in the *document*: the row it belongs on usually holds
-- a line that is nowhere near the screen, and an extmark can only be attached to a line the
-- window is showing. At the end of a long page that left almost every mark undrawable.
local M = {}

local config = require('chatora.config')

M.ns = vim.api.nvim_create_namespace('chatora_scrollbar')

-- Fills the right half of its cell, so the bar reads as a rule against the window edge
-- rather than as characters someone typed.
local MARK = '▐'
local BLANK = ' '

--- Which mark wins when two of them land on the same row: the reader's own unsaved text
--- first, then what arrived while they were reading.
local RANK = { own = 3, updated = 2, unread = 1 }

local HL = {
  own = 'ChatoraTelomereLocal',
  updated = 'ChatoraTelomereUpdated',
  unread = 'ChatoraTelomereUnread',
}

-- The handle is a background and the marks are glyphs, so a change inside the part of the
-- page on screen still shows: they share the cell instead of one hiding the other.
local HANDLE_HL = 'ChatoraScrollbarHandle'
local HANDLE_PRIORITY = 100
local MARK_PRIORITY = 200

--- One bar per window showing a page, keyed by that window.
local bars = {}

local function enabled()
  local opts = config.options.telomere
  if opts == false then
    return false
  end
  return type(opts) ~= 'table' or opts.scrollbar ~= false
end

--- The handle sits at the hairline shade — it is the one part not saying that anything
--- happened, so it has to read as a position without reading as news. `ChatoraScrollbarBg`
--- is what makes the rows around it look like no window at all.
local function ensure_hl()
  vim.api.nvim_set_hl(0, HANDLE_HL, {
    bg = require('chatora.highlight').hairline(),
    default = true,
  })
  vim.api.nvim_set_hl(0, 'ChatoraScrollbarBg', { link = 'Normal', default = true })
end

--- Take down every bar whose window is gone, or whose window has moved on to something
--- else. A bar is a floating window anchored to another one, and Neovim keeps it open when
--- that one closes — so this is what stops one hanging over whatever took its place.
local sweep

local function close(win)
  local bar = bars[win]
  if not bar then
    return
  end
  bars[win] = nil
  if vim.api.nvim_win_is_valid(bar.win) then
    pcall(vim.api.nvim_win_close, bar.win, true)
  end
  if vim.api.nvim_buf_is_valid(bar.buf) then
    pcall(vim.api.nvim_buf_delete, bar.buf, { force = true })
  end
end

--- The bar window for `win`, sized and placed against its right edge.
local function ensure_bar(win, height)
  local anchor = {
    relative = 'win',
    win = win,
    row = 0,
    col = vim.api.nvim_win_get_width(win) - 1,
    width = 1,
    height = height,
  }
  local bar = bars[win]
  if bar and vim.api.nvim_win_is_valid(bar.win) and vim.api.nvim_buf_is_valid(bar.buf) then
    pcall(vim.api.nvim_win_set_config, bar.win, anchor)
    return bar
  end
  close(win)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'chatora_scrollbar'
  -- Never focused and never in the way: it is a picture of the page, not a place to be.
  local ok, float = pcall(vim.api.nvim_open_win, buf, false, {
    focusable = false,
    style = 'minimal',
    zindex = 10,
    noautocmd = true,
    relative = anchor.relative,
    win = anchor.win,
    row = anchor.row,
    col = anchor.col,
    width = anchor.width,
    height = anchor.height,
  })
  if not ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return nil
  end
  vim.wo[float].winhighlight = 'Normal:ChatoraScrollbarBg,NormalFloat:ChatoraScrollbarBg'
  vim.wo[float].wrap = false
  bar = { win = float, buf = buf, bufnr = vim.api.nvim_win_get_buf(win) }
  bars[win] = bar
  return bar
end

sweep = function()
  for win, entry in pairs(bars) do
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= entry.bufnr then
      close(win)
    end
  end
end

-- Window lifetime is nobody's buffer-local business: a window can close, or take up another
-- buffer, without the page ever hearing about it.
vim.api.nvim_create_autocmd({ 'WinClosed', 'WinEnter', 'BufWinEnter', 'BufWinLeave', 'TabEnter' }, {
  group = vim.api.nvim_create_augroup('ChatoraScrollbarWindows', { clear = true }),
  callback = function()
    vim.schedule(sweep)
  end,
})

--- Rows the handle covers, as `first, last` (0-based), sized the way a scrollbar's is: the
--- share of the page on screen, held constant while it slides from top to bottom.
---
--- Not the document positions of the first and last visible lines, which is what a page far
--- longer than the window collapses into a single row — and what grows and shrinks as
--- wrapped lines change how many lines fit on a screen.
local function handle_rows(topline, total, height)
  local size = math.max(1, math.floor(height * height / total))
  local travel = math.max(1, total - height)
  local reached = math.max(0, math.min(1, (topline - 1) / travel))
  local first = math.floor((height - size) * reached + 0.5)
  return first, first + size - 1
end

--- The kind of change to mark on each row (0-based), nil where there is none.
---
--- Every mark is placed by its share of the document, so its row says where in the page as a
--- whole the change is, whether or not that part of the page is on screen.
local function mark_rows(marks, total, height)
  local kinds = {}
  for _, mark in ipairs(marks) do
    local row = math.max(0, math.min(height - 1, math.floor((mark.row - 1) / total * height)))
    if not kinds[row] or RANK[mark.kind] > RANK[kinds[row]] then
      kinds[row] = mark.kind
    end
  end
  return kinds
end

--- Draw the bar for one window showing `bufnr`.
local function render(win, bufnr)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local info = vim.fn.getwininfo(win)[1]
  if not info or info.height < 1 then
    return close(win)
  end
  -- A page shorter than the window has nothing to scroll to and nothing to point at: every
  -- one of its lines already wears its own telomere in the gutter.
  if total <= info.height then
    return close(win)
  end

  local marks = require('chatora.telomere').rows(bufnr)
  -- A page that is new all the way through points at itself, which is no help; Cosense
  -- hides its overlay in the same case.
  if #marks >= total then
    marks = {}
  end

  local bar = ensure_bar(win, info.height)
  if not bar then
    return
  end
  local kinds = mark_rows(marks, total, info.height)

  local lines = {}
  for row = 0, info.height - 1 do
    lines[row + 1] = kinds[row] and MARK or BLANK
  end
  vim.api.nvim_buf_set_lines(bar.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bar.buf, M.ns, 0, -1)

  local first, last = handle_rows(info.topline, total, info.height)
  for row = first, last do
    vim.api.nvim_buf_set_extmark(bar.buf, M.ns, row, 0, {
      line_hl_group = HANDLE_HL,
      priority = HANDLE_PRIORITY,
    })
  end
  for row, kind in pairs(kinds) do
    vim.api.nvim_buf_set_extmark(bar.buf, M.ns, row, 0, {
      end_col = #MARK,
      hl_group = HL[kind],
      priority = MARK_PRIORITY,
    })
  end
end

--- Redraw the bar in every window showing `bufnr`, and take down the ones left behind.
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  sweep()
  if not vim.api.nvim_buf_is_valid(bufnr) or not enabled() then
    return
  end
  ensure_hl()
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      render(win, bufnr)
    end
  end
end

--- The line that bar row `row` (0-based) stands for. The inverse of where `bar_rows` puts a
--- mark, so following one lands on the change it points at.
function M.line_at(row, total, height)
  return math.max(1, math.min(total, math.floor(row / height * total) + 1))
end

--- Move the view to what was clicked on the bar, and say whether the click was on one.
---
--- The bar is not focusable, so a click over it is reported against the window underneath;
--- what identifies it is the column — the bar owns the window's last one.
function M.click()
  local pos = vim.fn.getmousepos()
  local win = pos.winid
  if not bars[win] or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  if pos.wincol < vim.api.nvim_win_get_width(win) then
    return false
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  local info = vim.fn.getwininfo(win)[1]
  local line = M.line_at(pos.winrow - 1, vim.api.nvim_buf_line_count(bufnr), info.height)
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_win_set_cursor(win, { line, 0 })
    vim.cmd('normal! zz')
  end)
  M.refresh(bufnr)
  return true
end

--- Follow the view: the bar is a picture of where the reader is, so scrolling or resizing
--- redraws it even though nothing about the page changed.
function M.attach(bufnr)
  if vim.b[bufnr].chatora_scrollbar_attached then
    return
  end
  vim.b[bufnr].chatora_scrollbar_attached = true
  local group = vim.api.nvim_create_augroup('ChatoraScrollbar' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ 'WinScrolled', 'WinResized', 'BufWinEnter', 'ColorScheme' }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.refresh(bufnr)
    end,
  })
  vim.keymap.set('n', '<LeftMouse>', function()
    if not M.click() then
      -- Not on the bar: the click is the editor's own business.
      vim.api.nvim_feedkeys(vim.keycode('<LeftMouse>'), 'ni', false)
    end
  end, { buffer = bufnr, desc = 'chatora: スクロールバーの位置へ移動' })
end

return M
