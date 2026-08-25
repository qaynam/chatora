-- Keeps an open page in step with the server without ever discarding what is in the
-- buffer. Every path here goes through `chatora/syncPage`, which merges the server's
-- current lines into the buffer's unsaved edits rather than replacing them; a line the
-- two disagree about keeps the local text and comes back as a conflict.
--
-- Polling follows the window, not the clock: a page nobody is looking at costs nothing,
-- and returning to one fetches immediately instead of waiting out a tick.
local M = {}

local lsp = require('chatora.lsp')

M.ns = vim.api.nvim_create_namespace('chatora_sync')

local uv = vim.uv or vim.loop
local timers = {}
local in_flight = {}
local conflicts_by_bufnr = {}

local function options()
  local opt = require('chatora.config').options.sync
  if opt == false then
    return nil
  end
  if type(opt) ~= 'table' then
    opt = {}
  end
  return {
    interval = math.max(5, tonumber(opt.interval) or 30),
    on_focus = opt.on_focus ~= false,
    notify = opt.notify ~= false,
  }
end

local function ensure_hl()
  vim.api.nvim_set_hl(0, 'ChatoraConflict', { link = 'DiffText', default = true })
  vim.api.nvim_set_hl(0, 'ChatoraConflictRemote', { link = 'DiagnosticVirtualTextWarn', default = true })
end

--- A page buffer whose content has actually landed. The flag matters: BufEnter fires while
--- BufReadCmd's fetch is still out, and merging an empty buffer against the server's copy
--- would read as "the user deleted everything".
local function is_page(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr)
    and vim.api.nvim_buf_get_name(bufnr):match('^cosense://') ~= nil
    and vim.b[bufnr].chatora_attached == true
end

--- Conflicts currently marked in bufnr, in buffer order.
function M.conflicts(bufnr)
  return conflicts_by_bufnr[bufnr or vim.api.nvim_get_current_buf()] or {}
end

local function label(conflict)
  if conflict.theirs == nil or conflict.theirs == vim.NIL then
    return 'サーバーでは削除されています'
  end
  if conflict.ours == nil or conflict.ours == vim.NIL then
    return 'ローカルでは削除しています / サーバー: ' .. conflict.theirs
  end
  return 'サーバー: ' .. conflict.theirs
end

--- Mark every conflicted line, replacing whatever the previous sync marked. The remote text
--- is shown rather than written in: the buffer must stay byte-identical to what a save
--- would send, so a conflict can never leak marker lines into the page.
local function mark(bufnr, conflicts)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  conflicts_by_bufnr[bufnr] = conflicts
  if #conflicts == 0 then
    return
  end
  ensure_hl()
  local last = vim.api.nvim_buf_line_count(bufnr) - 1
  for _, conflict in ipairs(conflicts) do
    local row = math.min(conflict.line, last)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, 0, {
      line_hl_group = 'ChatoraConflict',
      virt_text = { { '  ◆ ' .. label(conflict), 'ChatoraConflictRemote' } },
      virt_text_pos = 'eol',
    })
  end
end

--- Drop the conflict marks, once the lines they describe are no longer meaningful.
function M.clear(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  conflicts_by_bufnr[bufnr] = nil
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns, 0, -1)
  end
end

--- Replace bufnr's lines with `text`, keeping the cursor where it was and leaving the
--- buffer modified: a merge is unsaved work like anything the user typed.
local function apply(bufnr, text)
  local lines = vim.split(text or '', '\n', { plain = true })
  local winid = vim.fn.bufwinid(bufnr)
  local cursor = winid ~= -1 and vim.api.nvim_win_get_cursor(winid) or nil
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  if cursor and vim.api.nvim_win_is_valid(winid) then
    pcall(vim.api.nvim_win_set_cursor, winid, { math.min(cursor[1], #lines), cursor[2] })
  end
  require('chatora.images').invalidate(bufnr)
end

--- Show the merge a refused save came back with. The buffer keeps its modified flag: this
--- is unsaved work, and the save that produced it did not happen.
function M.apply_conflicts(bufnr, text, conflicts)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if text then
    apply(bufnr, text)
  end
  mark(bufnr, conflicts)
end

--- Merge the server's copy into bufnr. `cb(changed, conflicts)` runs when it lands.
---
--- One request at a time per buffer: a caller arriving while a sync is out waits on that
--- one rather than starting a second, so a slow network cannot build a backlog of merges
--- and a hand-triggered pull still gets its answer instead of silently doing nothing.
function M.run(bufnr, cb)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not is_page(bufnr) then
    if cb then
      cb(false, {})
    end
    return
  end
  local waiting = in_flight[bufnr]
  if waiting then
    if cb then
      waiting[#waiting + 1] = cb
    end
    return
  end
  waiting = cb and { cb } or {}
  in_flight[bufnr] = waiting

  lsp.request('chatora/syncPage', { uri = vim.api.nvim_buf_get_name(bufnr) }, function(err, result)
    in_flight[bufnr] = nil
    local changed, conflicts = false, {}
    if not (err or not result or result.ok == false or not vim.api.nvim_buf_is_valid(bufnr)) then
      changed = result.changed == true
      conflicts = result.conflicts or {}
      if changed then
        apply(bufnr, result.text)
      end
      mark(bufnr, conflicts)
      if result.meta then
        vim.b[bufnr].chatora_meta = result.meta
      end
      require('chatora.status').sync(bufnr)
    end
    for _, pending in ipairs(waiting) do
      pending(changed, conflicts)
    end
  end)
end

local function stop(bufnr)
  local timer = timers[bufnr]
  if timer then
    pcall(function()
      timer:stop()
      timer:close()
    end)
    timers[bufnr] = nil
  end
end

--- Poll bufnr until it stops being the buffer on screen. Restarting an already-running
--- poll is a no-op, so every BufEnter does not cost a new timer.
local function start(bufnr)
  local opts = options()
  if not opts or timers[bufnr] or not is_page(bufnr) then
    return
  end
  local timer = uv.new_timer()
  timers[bufnr] = timer
  timer:start(
    opts.interval * 1000,
    opts.interval * 1000,
    vim.schedule_wrap(function()
      if not (vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_get_current_buf() == bufnr) then
        stop(bufnr)
        return
      end
      M.run(bufnr)
    end)
  )
end

--- Poll bufnr from now on, without syncing first. For a page that was just loaded, where
--- the buffer and the base are the same thing and a sync would be one wasted request.
function M.watch(bufnr)
  start(bufnr or vim.api.nvim_get_current_buf())
end

--- Sync now and resume polling — what returning to a page does.
function M.resume(bufnr)
  local opts = options()
  if not opts then
    return
  end
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not is_page(bufnr) then
    return
  end
  start(bufnr)
  if opts.on_focus then
    M.run(bufnr, function(changed, conflicts)
      if not opts.notify then
        return
      end
      if #conflicts > 0 then
        vim.notify(
          ('[chatora] リモートと競合する行が %d 件あります（ローカルの内容は残しています）'):format(#conflicts),
          vim.log.levels.WARN
        )
      elseif changed then
        vim.notify('[chatora] リモートの変更を取り込みました')
      end
    end)
  end
end

function M.pause(bufnr)
  stop(bufnr or vim.api.nvim_get_current_buf())
end

--- Move the cursor to the next conflict at or after the current line, wrapping.
function M.next_conflict()
  local bufnr = vim.api.nvim_get_current_buf()
  local list = M.conflicts(bufnr)
  if #list == 0 then
    vim.notify('[chatora] 競合はありません')
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local target = list[1]
  for _, conflict in ipairs(list) do
    if conflict.line > row then
      target = conflict
      break
    end
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { target.line + 1, 0 })
end

local augroup = vim.api.nvim_create_augroup('ChatoraSync', { clear = true })

vim.api.nvim_create_autocmd({ 'BufEnter', 'FocusGained' }, {
  group = augroup,
  pattern = 'cosense://*',
  callback = function(ev)
    M.resume(ev.buf)
  end,
})

-- A page left behind, or a Neovim that lost the terminal's focus, is a page nobody is
-- reading; polling it would spend requests on a screen that is not being looked at.
vim.api.nvim_create_autocmd({ 'BufLeave', 'FocusLost' }, {
  group = augroup,
  pattern = 'cosense://*',
  callback = function(ev)
    M.pause(ev.buf)
  end,
})

vim.api.nvim_create_autocmd('BufWipeout', {
  group = augroup,
  pattern = 'cosense://*',
  callback = function(ev)
    stop(ev.buf)
    conflicts_by_bufnr[ev.buf] = nil
    in_flight[ev.buf] = nil
  end,
})

return M
