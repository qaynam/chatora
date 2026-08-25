-- Cosense's visual-mode decoration keys: with text selected, the marker character wraps it
-- in that notation — `*` gives `[* text]`, `[` gives the link form `[text]`, and so on.
--
-- Pressing the same marker again rewrites the run inside the brackets rather than nesting
-- a second pair, which is what makes `***` reachable by repeating `*`.
local M = {}

local config = require('chatora.config')

-- Cosense stops growing emphasis at five asterisks (same ceiling the server's notations.ts
-- applies when it turns a marker run into a token).
local MAX_ASTERISKS = 5

local OFFICIAL = { '*', '/', '-', '_' }

--- Marker characters the visual keys are bound to: Cosense's own four, the link bracket,
--- and whatever markers the user defined notations for.
local function markers()
  local opts = config.options.surround
  if opts == false then
    return {}
  end
  if type(opts) == 'table' and vim.islist(opts) then
    return opts
  end
  local list = { '[' }
  vim.list_extend(list, OFFICIAL)
  for marker in pairs(config.options.notations or {}) do
    if type(marker) == 'string' and #marker == 1 and not vim.tbl_contains(list, marker) then
      list[#list + 1] = marker
    end
  end
  return list
end

--- The visual selection as (row, start_col, end_col, line), the columns 0-based and the end
--- exclusive, or nil when it is not one line of one buffer. Read from the live selection
--- rather than the `'<`/`'>` marks, which only catch up once visual mode has been left.
local function selection()
  local anchor = vim.fn.getpos('v')
  local cursor = vim.fn.getpos('.')
  if anchor[2] ~= cursor[2] then
    return nil
  end
  local row = anchor[2] - 1
  local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1]
  if not line then
    return nil
  end
  local from = math.min(anchor[3], cursor[3]) - 1
  local last = math.max(anchor[3], cursor[3]) - 1
  -- Both are the *first byte* of a character. An inclusive selection (the default) covers
  -- all of the last one, so its whole multibyte sequence has to be stepped over.
  local to = last
  if vim.o.selection ~= 'exclusive' then
    to = last + #(line:sub(last + 1):match('^[\1-\127\194-\244][\128-\191]*') or ' ')
  end
  return row, from, math.min(to, #line), line
end

--- Put the visual selection back over [from, to) on `row`. Goes through the `'<`/`'>` marks
--- and `gv` rather than re-entering visual mode by hand: the edit just made has already
--- dropped the old selection, and gv is what restores one from marks.
local function reselect(row, from, to)
  if to <= from then
    return
  end
  vim.fn.setpos("'<", { 0, row + 1, from + 1, 0 })
  vim.fn.setpos("'>", { 0, row + 1, to, 0 })
  vim.cmd('normal! gv')
end

--- The notation already bracketing the selection, as (start, stop, run) with `start`
--- 0-based and `stop` exclusive, or nil. The brackets sit *outside* the selection because
--- a wrap leaves only the body selected — which is what lets a second press rewrite the
--- run instead of nesting another pair. `run` is empty for a plain `[link]`.
local function enclosing(line, from, to)
  if line:sub(to + 1, to + 1) ~= ']' then
    return nil
  end
  local prefix = line:sub(1, from)
  local at, run = prefix:match('()%[([^%s%[%]]+)%s$')
  if at then
    return at - 1, to + 1, run
  end
  at = prefix:match('()%[$')
  if at then
    return at - 1, to + 1, ''
  end
  return nil
end

--- The marker run an existing decoration should carry once `marker` is pressed again, or
--- nil to drop the notation entirely. Asterisks accumulate — that is how `[*** ]` is
--- reached by pressing `*` three times — while every other marker toggles.
local function next_run(run, marker)
  if marker == '*' then
    local count = select(2, run:gsub('%*', ''))
    if count >= MAX_ASTERISKS then
      return run
    end
    return run:gsub('%*', '') .. string.rep('*', count + 1)
  end
  if not run:find(marker, 1, true) then
    return run .. marker
  end
  local without = (run:gsub(vim.pesc(marker), ''))
  return without ~= '' and without or nil
end

local function decorate(run, body)
  return run == '' and '[' .. body .. ']' or '[' .. run .. ' ' .. body .. ']'
end

--- Wrap the visual selection in `marker`'s notation.
---
--- A decoration marker leaves the body selected, which is what lets the key be pressed
--- again to build on its own result — `[*** ]` is three presses of `*`. `[` has nothing to
--- build, so it returns to normal mode with the cursor on the text it just linked.
function M.wrap(marker)
  local row, from, to, line = selection()
  if not row then
    vim.notify('[chatora] 装飾記法は 1 行の選択にだけ使えます', vim.log.levels.WARN)
    return
  end
  local selected = line:sub(from + 1, to)
  if selected == '' then
    return
  end

  local start, stop, run = enclosing(line, from, to)
  local body, replacement = selected, nil
  if start and marker == '[' then
    replacement = selected
  elseif start and run ~= '' then
    local updated = next_run(run, marker)
    replacement = updated == nil and selected or decorate(updated, selected)
  elseif start then
    -- A plain `[link]` decorated is `[* [link]]`: the brackets are the link, and the
    -- decoration has to go outside them or it stops being one.
    body = line:sub(start + 1, stop)
    replacement = decorate(marker, body)
  else
    replacement = decorate(marker == '[' and '' or marker, selected)
  end

  local edit_from, edit_to = start and start or from, start and stop or to
  vim.api.nvim_buf_set_text(0, row, edit_from, row, edit_to, { replacement })
  -- One deliberate action, not a burst of typing: settle the markup now rather than making
  -- the reader watch the brackets they just added sit there for a debounce interval.
  local bufnr = vim.api.nvim_get_current_buf()
  require('chatora.render').refresh(bufnr)
  require('chatora.pads').render(bufnr)
  local offset = replacement == body and 0 or (replacement:find(body, 1, true) or 1) - 1
  local body_at = edit_from + offset
  if marker == '[' then
    vim.cmd('normal! \27')
    vim.api.nvim_win_set_cursor(0, { row + 1, body_at })
    return
  end
  reselect(row, body_at, body_at + #body)
end

--- Bind every marker in visual mode on a page buffer.
function M.attach(bufnr)
  for _, marker in ipairs(markers()) do
    vim.keymap.set('x', marker, function()
      M.wrap(marker)
    end, {
      buffer = bufnr,
      silent = true,
      desc = 'chatora: 選択を ' .. (marker == '[' and '[ ]' or '[' .. marker .. ' ]') .. ' で囲む',
    })
  end
end

return M
