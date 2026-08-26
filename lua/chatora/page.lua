-- BufReadCmd/BufWriteCmd for cosense://<project>/<encoded title> buffers.
local M = {}

local uri = require('chatora.uri')
local lsp = require('chatora.lsp')
local related = require('chatora.related')
local codeblock = require('chatora.codeblock')
local images = require('chatora.images')
local pads = require('chatora.pads')
local config = require('chatora.config')
local status = require('chatora.status')

local uv = vim.uv or vim.loop
local autosave_timers = {}

-- A row requested for a page that is not open yet, kept by uri until its text arrives.
-- Following a `[title#lineId]` link is the one thing that asks for this.
local pending_row = {}

--- Put the cursor on the row this page was opened for, if it was opened for one.
local function apply_pending_row(bufnr)
  local wanted = pending_row[vim.api.nvim_buf_get_name(bufnr)]
  if not wanted then
    return
  end
  pending_row[vim.api.nvim_buf_get_name(bufnr)] = nil
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    return
  end
  local last = vim.api.nvim_buf_line_count(bufnr)
  pcall(vim.api.nvim_win_set_cursor, winid, { math.min(wanted, last), 0 })
  vim.api.nvim_win_call(winid, function()
    vim.cmd('normal! zz')
  end)
end

-- Forward declaration: autosave fires the save, which is defined with the write path.
local send_save

--- Debounced autosave: (re)arm the buffer's timer; fires config.autosave
--- seconds (minimum 1s) after the last edit, saving only if still modified.
local function schedule_autosave(bufnr)
  local secs = config.options.autosave
  if not secs or secs == false then
    return
  end
  local timer = autosave_timers[bufnr]
  if not timer then
    timer = uv.new_timer()
    autosave_timers[bufnr] = timer
  end
  timer:stop()
  timer:start(
    math.max(1000, math.floor(secs * 1000)),
    0,
    vim.schedule_wrap(function()
      if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].modified then
        -- Not `:write`: that is BufWriteCmd, which blocks the editor until the save
        -- round-trips because `:wq` needs it to. Nothing is waiting on an autosave, so it
        -- goes straight to the request and the cursor keeps moving while it is in flight.
        send_save(bufnr)
      end
    end)
  )
end

local function drop_autosave(bufnr)
  local timer = autosave_timers[bufnr]
  if timer then
    timer:stop()
    timer:close()
    autosave_timers[bufnr] = nil
  end
end

--- Replace buffer content without polluting undo history.
local function set_content(bufnr, text)
  local lines = vim.split(text or '', '\n', { plain = true })
  local ul = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].undolevels = ul
  -- Replacing every line destroys the extmarks image placements ride on, while
  -- leaving the set of images in the text identical.
  images.invalidate(bufnr)
end

local function refresh_sidebar_marks()
  -- Lazy require: sidebar requires page at load time, so requiring it at the
  -- top here would be circular.
  require('chatora.sidebar').refresh_marks()
end

local title_margin_ns = vim.api.nvim_create_namespace('chatora_title_margin')

-- Visual breathing room below the title line without touching buffer content
-- (the buffer must stay byte-identical to what gets saved to Cosense).
local function apply_title_margin(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, title_margin_ns, 0, -1)
  local margin = config.options.title_margin
  if type(margin) ~= 'number' or margin < 1 or vim.api.nvim_buf_line_count(bufnr) == 0 then
    return
  end
  local blank_lines = {}
  for i = 1, math.floor(margin) do
    blank_lines[i] = { { '', 'Normal' } }
  end
  vim.api.nvim_buf_set_extmark(bufnr, title_margin_ns, 0, 0, { virt_lines = blank_lines })
end

local function finalize_buffer(bufnr, project, title)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.bo[bufnr].modified = false
  apply_title_margin(bufnr)
  lsp.ensure_start(bufnr)
  related.on_page_opened(project, title)
  -- The load is over, so drop 'loading' before syncing: sync deliberately
  -- refuses to overwrite a pending state.
  status.set(bufnr, 'clean')
  status.sync(bufnr)
  -- on_lines is the only change notification that fires for every kind of
  -- edit (typing, API, :normal); TextChanged/BufModifiedSet miss scripted
  -- changes. Drives the save-state indicator (and through it the sidebar's
  -- unsaved ● marks).
  if not vim.b[bufnr].chatora_attached then
    vim.b[bufnr].chatora_attached = true
    vim.api.nvim_buf_attach(bufnr, false, {
      on_lines = function()
        vim.schedule(function()
          status.sync(bufnr)
          schedule_autosave(bufnr)
        end)
      end,
      on_detach = function()
        vim.schedule(function()
          pcall(vim.api.nvim_buf_set_var, bufnr, 'chatora_attached', false)
          drop_autosave(bufnr)
          status.forget(bufnr)
          refresh_sidebar_marks()
        end)
      end,
    })
  end
  vim.keymap.set('n', 'gR', function()
    related.toggle()
  end, { buffer = bufnr, nowait = true, silent = true, desc = 'chatora: 関連ページパネルをトグル' })
  -- External URLs open in the browser (confirmed first); everything else is
  -- the normal LSP definition jump into another cosense:// buffer.
  vim.keymap.set('n', 'gd', function()
    require('chatora.links').goto_definition()
  end, {
    buffer = bufnr,
    nowait = true,
    silent = true,
    desc = 'chatora: リンク先へジャンプ / 外部 URL はブラウザで開く',
  })
  vim.keymap.set('n', 'gs', function()
    require('chatora').search()
  end, { buffer = bufnr, nowait = true, silent = true, desc = 'chatora: ページ検索' })
  -- ]c is vim's own "next diff hunk"; a merge conflict is the same kind of thing to step
  -- through, and diff mode is never on in a page buffer.
  vim.keymap.set('n', ']c', function()
    require('chatora.sync').next_conflict()
  end, { buffer = bufnr, nowait = true, silent = true, desc = 'chatora: 次の競合へ' })
  -- ]u / [u step through what the right-edge marks point at.
  vim.keymap.set('n', ']u', function()
    require('chatora.telomere').jump(1)
  end, { buffer = bufnr, nowait = true, silent = true, desc = 'chatora: 次の更新行へ' })
  vim.keymap.set('n', '[u', function()
    require('chatora.telomere').jump(-1)
  end, { buffer = bufnr, nowait = true, silent = true, desc = 'chatora: 前の更新行へ' })

  codeblock.attach(bufnr)
  images.attach(bufnr, project)
  require('chatora.telomere').attach(bufnr)
  require('chatora.scrollbar').attach(bufnr)
  pads.attach(bufnr)
  require('chatora.table').attach(bufnr)
  require('chatora.render').attach(bufnr)
  require('chatora.spacing').attach(bufnr)
  require('chatora.completion').attach(bufnr)
  require('chatora.keymaps').attach(bufnr)
  require('chatora.surround').attach(bufnr)
  require('chatora.emptylink').attach(bufnr)
  -- BufEnter fired while this page's content was still being fetched, when sync refuses to
  -- touch the buffer, so the poll has to be started from here instead.
  require('chatora.sync').watch(bufnr)
end

-- Keys that begin an edit. On a buffer with 'modifiable' off Neovim answers all of them
-- with E21, which says the option is set but not why it was — and the reason (this is
-- someone else's project) is the only part the reader cannot work out.
local EDIT_KEYS = {
  'i', 'I', 'a', 'A', 'o', 'O',
  'c', 'C', 's', 'S', 'x', 'X', 'd', 'D', 'r', 'R', 'p', 'P', 'J', '~',
  '<BS>', '<Del>',
}

--- Lock bufnr against editing and answer attempts to type into it by name.
---
--- 'modifiable' alone answers every edit with E21, which reports that the option is set
--- without saying why — and why (this is someone else's project) is the only part the
--- reader cannot work out for themselves.
function M.mark_read_only(bufnr, project)
  vim.b[bufnr].chatora_read_only = true
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  local function say()
    vim.notify(
      ('[chatora] %s には書き込み権限がありません（読み取り専用）'):format(project),
      vim.log.levels.WARN
    )
  end
  for _, key in ipairs(EDIT_KEYS) do
    vim.keymap.set({ 'n', 'x' }, key, say, {
      buffer = bufnr,
      nowait = true,
      silent = true,
      desc = 'chatora: 読み取り専用の理由を知らせる',
    })
  end
end

local function handle_read(ev)
  local project, title = uri.parse(ev.match)
  if not project or not title then
    vim.notify('[chatora] invalid cosense uri: ' .. ev.match, vim.log.levels.ERROR)
    return
  end

  local bufnr = ev.buf
  -- Set buffer options synchronously, before the async fetch: UI plugins
  -- (winbar/statusline/icon providers) react to the buffer as soon as
  -- BufReadCmd returns, and must see a typed special buffer, not a normal
  -- file buffer with a percent-encoded name.
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'cosense'
  -- Cosense indentation: 1 whitespace char = 1 level, tabs included. Rendering a tab as
  -- one cell is what makes that true on screen as well — at any wider tab stop a
  -- tab-indented line sits at a different depth from its space-indented sibling, and the
  -- pads cannot correct for it because a tab's width depends on where it starts.
  vim.bo[bufnr].expandtab = true
  vim.bo[bufnr].shiftwidth = 1
  vim.bo[bufnr].softtabstop = 1
  vim.bo[bufnr].tabstop = 1
  -- Indentation is structure in Cosense, not decoration: a code block is exactly the
  -- lines indented deeper than its `code:` marker, so a new line at column 0 silently
  -- *ends the block*. Carrying the previous indent is what the web editor does.
  vim.bo[bufnr].autoindent = true

  status.set(bufnr, 'loading')
  lsp.request_ok('chatora/openPage', { project = project, title = title }, function(result)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    set_content(bufnr, result.text)
    apply_pending_row(bufnr)
    vim.b[bufnr].chatora_meta = result.meta
    -- Following a [/other-project/page] link lands on a project this session may only read.
    -- The buffer says so rather than letting the edit fail at save time, hours later.
    if result.readOnly then
      M.mark_read_only(bufnr, project)
    end
    finalize_buffer(bufnr, project, title)
  end)
end

--- Cosense's own numbers for the page in bufnr (updated/views/linked/…), or nil
--- before the fetch lands and for a page that does not exist yet.
function M.meta(bufnr)
  return vim.b[bufnr or vim.api.nvim_get_current_buf()].chatora_meta
end

local SAVE_TIMEOUT_MS = 15000

--- Handle one savePage reply. `tick` is the buffer's changedtick when the request went
--- out: an autosave runs without blocking, so by the time it lands the user may have typed
--- on. Anything that would speak for the whole buffer — clearing 'modified', replacing the
--- text the server normalized — is skipped in that case. The base is left pointing at what
--- was actually saved, so the next save diffs against it and picks the rest up.
local function apply_save(bufnr, uri_str, save_err, save_result, tick)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local current = vim.b[bufnr].changedtick
  local unchanged = tick == nil or current == tick

  if save_err then
    local msg = type(save_err) == 'table' and (save_err.message or vim.inspect(save_err))
      or tostring(save_err)
    status.set(bufnr, 'error')
    vim.notify('[chatora] ' .. msg, vim.log.levels.ERROR)
    return
  end

  local result = save_result
  if not result or result.ok == false then
    local code = result and result.code
    status.set(bufnr, 'error')
    if code == 'conflict' then
      -- The server rebuilt the save against its current copy and found lines both sides
      -- had touched. The merge is applied so the remote changes are visible, the local
      -- text is what survives on the conflicted lines, and the buffer stays modified —
      -- nothing was written, and resolving is the user's next edit.
      local sync = require('chatora.sync')
      sync.apply_conflicts(bufnr, result.text, result.conflicts or {})
      vim.notify(
        ('[chatora] リモートと同じ行を編集しています（競合 %d 件）。ローカルの内容は残してあります。]c で移動して直してから再保存してください'):format(
          #(result.conflicts or {})
        ),
        vim.log.levels.WARN
      )
    elseif code == 'notFastForward' then
      vim.notify(
        '[chatora] リモートが更新されています。<leader>cf で取り込んでから保存してください',
        vim.log.levels.WARN
      )
    else
      vim.notify('[chatora] ' .. ((result and result.message) or 'save failed'), vim.log.levels.ERROR)
    end
    return
  end

  if result.text and unchanged then
    local winid = vim.fn.bufwinid(bufnr)
    local cursor = nil
    if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
      cursor = vim.api.nvim_win_get_cursor(winid)
    end
    set_content(bufnr, result.text)
    if cursor and vim.api.nvim_win_is_valid(winid) then
      local max_line = vim.api.nvim_buf_line_count(bufnr)
      pcall(vim.api.nvim_win_set_cursor, winid, { math.min(cursor[1], max_line), cursor[2] })
    end
  end

  if unchanged then
    vim.bo[bufnr].modified = false
  end
  -- Success feedback is one cmdline echo + the ✓ icon, not a toast; failures
  -- above still use vim.notify, where demanding attention is the point.
  status.set(bufnr, 'clean', '保存しました')
  -- What was the reader's own unsaved text a moment ago is now the server's, with a
  -- timestamp to match.
  require('chatora.telomere').refresh(bufnr)

  if result.titleChanged then
    -- Renaming the buffer in place would desync the LSP client (didOpen was sent for the
    -- old URI), so reopen the page under its new URI instead.
    local project = uri.parse(uri_str)
    local new_uri = uri.format(project, result.titleChanged.to)
    vim.notify(
      '[chatora] title changed: ' .. result.titleChanged.from .. ' -> ' .. result.titleChanged.to,
      vim.log.levels.INFO
    )
    local winid = vim.fn.bufwinid(bufnr)
    if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_call(winid, function()
        -- magic.file=false: the URI contains %XX escapes that :edit would
        -- otherwise expand as the "current file" special character.
        vim.cmd({ cmd = 'edit', args = { new_uri }, magic = { file = false } })
      end)
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
  end
end

--- Send the buffer to Cosense. `on_done()` runs once the reply has been applied.
function send_save(bufnr, on_done)
  local uri_str = vim.api.nvim_buf_get_name(bufnr)
  local tick = vim.b[bufnr].changedtick
  status.set(bufnr, 'saving', '保存中…')
  lsp.request('chatora/savePage', { uri = uri_str }, function(err, result)
    apply_save(bufnr, uri_str, err, result, tick)
    if on_done then
      on_done()
    end
  end)
end

--- BufWriteCmd. The reply is awaited synchronously because `:wq` and `:x` check 'modified'
--- the moment this returns — an async write would read as unsaved and demand a second
--- `:wq`. vim.wait pumps the main loop, which is what lets the reply land while we block.
--- Autosave does not come through here for exactly that reason: see schedule_autosave.
local function handle_write(ev)
  if vim.b[ev.buf].chatora_read_only then
    vim.notify(
      '[chatora] このプロジェクトには書き込めません（読み取り専用で開いています）',
      vim.log.levels.WARN
    )
    return
  end
  local done = false
  send_save(ev.buf, function()
    done = true
  end)
  if not vim.wait(SAVE_TIMEOUT_MS, function()
    return done
  end, 10) and vim.api.nvim_buf_is_valid(ev.buf) then
    status.set(ev.buf, 'error')
    vim.notify('[chatora] 保存がタイムアウトしました', vim.log.levels.ERROR)
  end
end

--- Titles of loaded cosense buffers with unsaved changes.
local function unsaved_titles()
  local titles = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
      local name = vim.api.nvim_buf_get_name(b)
      if name:match('^cosense://') then
        local _, title = uri.parse(name)
        titles[#titles + 1] = title or name
      end
    end
  end
  return titles
end

local augroup = vim.api.nvim_create_augroup('ChatoraPage', { clear = true })
vim.api.nvim_create_autocmd('BufReadCmd', { group = augroup, pattern = 'cosense://*', callback = handle_read })
vim.api.nvim_create_autocmd('BufWriteCmd', { group = augroup, pattern = 'cosense://*', callback = handle_write })

-- chatora:// UI buffers (sidebar, related panel) have nothing to write, but a
-- reflexive :wq in them should close the window instead of failing with E382 —
-- they use buftype=acwrite and this no-op accepts the write.
vim.api.nvim_create_autocmd('BufWriteCmd', {
  group = augroup,
  pattern = 'chatora://*',
  callback = function(ev)
    vim.bo[ev.buf].modified = false
  end,
})

-- Under 'hidden', :q on an unsaved page closes the window and leaves the buffer
-- modified in the background, with no prompt of any kind — so ask here. An
-- error thrown from QuitPre aborts the quit, which is what makes "cancel" work.
vim.api.nvim_create_autocmd('QuitPre', {
  group = augroup,
  pattern = 'cosense://*',
  callback = function(ev)
    if not vim.bo[ev.buf].modified or vim.v.exiting ~= vim.NIL then
      return
    end
    local _, title = uri.parse(vim.api.nvim_buf_get_name(ev.buf))
    local choice = vim.fn.confirm(
      '未保存の変更があります: ' .. (title or '?'),
      '保存して閉じる(&W)\n保存せず閉じる(&D)\nキャンセル(&C)',
      1
    )
    if choice == 1 then
      vim.api.nvim_buf_call(ev.buf, function()
        vim.cmd('write')
      end)
      -- A failed save leaves the buffer modified; closing anyway would be the
      -- one outcome the user did not pick.
      if vim.bo[ev.buf].modified then
        error('chatora: 保存に失敗したため閉じません')
      end
    elseif choice ~= 2 then
      error('chatora: 閉じるのをキャンセルしました')
    end
  end,
})

local function page_windows()
  local wins = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match('^cosense://') then
      wins[#wins + 1] = w
    end
  end
  return wins
end

-- chatora's chrome (sidebar, related panel) is only there to serve a page, so
-- closing the last page window takes it along. Without this, :q leaves the
-- panels behind and has to be repeated once per window to get out.
vim.api.nvim_create_autocmd('QuitPre', {
  group = augroup,
  pattern = 'cosense://*',
  callback = function()
    if #page_windows() > 1 then
      return
    end
    related.close()
    require('chatora.sidebar').close()
  end,
})

-- On exit, list every unsaved page in one place (Neovim's own E162 names
-- only the first offending buffer).
vim.api.nvim_create_autocmd('ExitPre', {
  group = augroup,
  callback = function()
    local titles = unsaved_titles()
    if #titles > 0 then
      vim.notify('[chatora] 未保存のページ: ' .. table.concat(titles, ', '), vim.log.levels.WARN)
    end
  end,
})

--- Open project/title (edits the cosense:// URI), optionally in target_win.
---
--- `opts.row` is a 1-based line to put the cursor on once the page has loaded. It cannot be
--- set here: the buffer has no lines until the fetch lands, so it is remembered and applied
--- by the read handler.
function M.open(project, title, target_win, opts)
  if target_win and vim.api.nvim_win_is_valid(target_win) then
    vim.api.nvim_set_current_win(target_win)
  end
  local uri_str = uri.format(project, title)
  if opts and opts.row then
    pending_row[uri_str] = opts.row
  end
  local already_loaded = vim.b[vim.fn.bufnr(uri_str)] ~= nil
    and vim.fn.bufnr(uri_str) ~= -1
    and vim.b[vim.fn.bufnr(uri_str)].chatora_attached == true
  -- magic.file=false: the URI contains %XX escapes that :edit would otherwise
  -- expand as the "current file" special character (E499 on Japanese titles).
  vim.cmd({ cmd = 'edit', args = { uri_str }, magic = { file = false } })
  -- `:edit` on a buffer that already holds its page does not read it again, so nothing
  -- would come along to apply the row. When the text is already there, apply it now.
  if already_loaded then
    apply_pending_row(vim.fn.bufnr(uri_str))
  end
end

return M
