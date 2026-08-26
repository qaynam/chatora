-- Where the changed lines are in the *whole* page, drawn as marks down the right edge of
-- the window. The telomere in the sign column only speaks for the lines on screen; this is
-- what says there is something worth scrolling to. Cosense draws the same thing over its
-- browser scrollbar (`.scroll-bar-overlay .unread-bar`).
local M = {}

local config = require('chatora.config')

M.ns = vim.api.nvim_create_namespace('chatora_scrollbar')

-- Fills the right half of its cell, so the marks read as a rule against the window edge
-- rather than as characters someone typed.
local MARK = '▐'

-- Over the semantic tokens (125), which own the text this is drawn on top of.
local PRIORITY = 200

--- Which mark wins when two of them land on the same row: the reader's own unsaved text
--- first, then what arrived while they were reading, and the handle under all of it — where
--- the view is matters less than what it is missing.
local RANK = { own = 4, updated = 3, unread = 2, handle = 1 }

local HL = {
  own = 'ChatoraTelomereLocal',
  updated = 'ChatoraTelomereUpdated',
  unread = 'ChatoraTelomereUnread',
  handle = 'ChatoraScrollbarHandle',
}

--- The handle is the one part not saying that anything happened, so it sits at the hairline
--- shade: enough to read as a position, not enough to read as news.
local function ensure_hl()
  vim.api.nvim_set_hl(0, 'ChatoraScrollbarHandle', {
    fg = require('chatora.highlight').hairline(),
    default = true,
  })
end

local function enabled()
  local opts = config.options.telomere
  if opts == false then
    return false
  end
  return type(opts) ~= 'table' or opts.scrollbar ~= false
end

--- Buffer line drawn at each row of the window, by row (0-based from the window's top).
---
--- Not simply `topline + row`: a wrapped line covers several rows and a fold covers none,
--- so the rows are read back from the screen. Continuation rows keep the line they belong
--- to, which is where its mark can be drawn.
local function lines_by_row(win, info)
  local out = {}
  local last = nil
  for lnum = info.topline, info.botline do
    local pos = vim.fn.screenpos(win, lnum, 1)
    if pos.row > 0 then
      local row = pos.row - info.winrow
      if row >= 0 and row < info.height then
        out[row] = lnum
        last = lnum
      end
    end
  end
  for row = 0, info.height - 1 do
    if out[row] == nil then
      out[row] = last
    else
      last = out[row]
    end
  end
  return out
end

--- Draw the overview for one window showing `bufnr`.
local function render(win, bufnr)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local info = vim.fn.getwininfo(win)[1]
  if not info or info.height < 1 then
    return
  end
  -- A page shorter than the window has nothing to scroll to and nothing to point at: every
  -- one of its lines already wears its own telomere in the gutter. Measured against the
  -- window's height rather than what is on screen right now, which lags an edit.
  if total <= info.height then
    return
  end

  local marks = require('chatora.telomere').rows(bufnr)
  -- A page that is new all the way through points at itself, which is no help; Cosense
  -- hides its overlay in the same case.
  local newsworthy = #marks > 0 and #marks < total

  local rows = lines_by_row(win, info)
  -- Everything is placed by its share of the document, the way a scrollbar is: line 1 at
  -- the top of the window, the last line at the bottom, wherever the view happens to be.
  local at = function(line)
    return math.max(0, math.min(info.height - 1, math.floor((line - 1) / total * info.height)))
  end
  local strongest = {}
  -- The handle covers what is on screen, so the marks outside it are the ones worth
  -- scrolling to, and its size says how much of the page is in front of the reader.
  for row = at(info.topline), at(info.botline) do
    strongest[row] = 'handle'
  end
  if newsworthy then
    for _, mark in ipairs(marks) do
      local row = at(mark.row)
      local current = strongest[row]
      if not current or RANK[mark.kind] > RANK[current] then
        strongest[row] = mark.kind
      end
    end
  end

  -- One extmark per *line*, since that is what an extmark can be attached to: two marks
  -- landing on rows of the same wrapped line would otherwise draw over each other.
  local drawn = {}
  for row, kind in pairs(strongest) do
    local lnum = rows[row]
    if lnum and not drawn[lnum] then
      drawn[lnum] = true
      -- Right-aligned rather than at a column worked out here: the gutters' width is the
      -- window's business and changes under us — the telomere's own signs widen it.
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, lnum - 1, 0, {
        virt_text = { { MARK, HL[kind] } },
        virt_text_pos = 'right_align',
        priority = PRIORITY,
      })
    end
  end
end

--- Redraw the overview in every window showing `bufnr`.
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  if not enabled() then
    return
  end
  ensure_hl()
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      render(win, bufnr)
    end
  end
end

--- Follow the view: the marks are positions in the window, so scrolling or resizing moves
--- every one of them even though nothing about the page changed.
function M.attach(bufnr)
  if vim.b[bufnr].chatora_scrollbar_attached then
    return
  end
  vim.b[bufnr].chatora_scrollbar_attached = true
  vim.api.nvim_create_autocmd({ 'WinScrolled', 'WinResized', 'BufWinEnter', 'ColorScheme' }, {
    group = vim.api.nvim_create_augroup('ChatoraScrollbar' .. bufnr, { clear = true }),
    buffer = bufnr,
    callback = function()
      M.refresh(bufnr)
    end,
  })
end

return M
