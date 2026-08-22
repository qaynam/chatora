-- BufReadCmd/BufWriteCmd for cosense://<project>/<encoded title> buffers.
local M = {}

local uri = require('chatora.uri')
local lsp = require('chatora.lsp')
local related = require('chatora.related')
local codeblock = require('chatora.codeblock')
local images = require('chatora.images')
local pads = require('chatora.pads')
local config = require('chatora.config')

local uv = vim.uv or vim.loop
local autosave_timers = {}

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
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd('silent write')
        end)
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
  refresh_sidebar_marks()
  -- on_lines is the only change notification that fires for every kind of
  -- edit (typing, API, :normal); TextChanged/BufModifiedSet miss scripted
  -- changes. Drives the sidebar's unsaved (●) marks.
  if not vim.b[bufnr].chatora_attached then
    vim.b[bufnr].chatora_attached = true
    vim.api.nvim_buf_attach(bufnr, false, {
      on_lines = function()
        vim.schedule(function()
          refresh_sidebar_marks()
          schedule_autosave(bufnr)
        end)
      end,
      on_detach = function()
        vim.schedule(function()
          pcall(vim.api.nvim_buf_set_var, bufnr, 'chatora_attached', false)
          drop_autosave(bufnr)
          refresh_sidebar_marks()
        end)
      end,
    })
  end
  vim.keymap.set('n', 'gR', function()
    related.toggle()
  end, { buffer = bufnr, nowait = true, silent = true })
  vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { buffer = bufnr, nowait = true, silent = true })
  vim.keymap.set('n', 'gs', function()
    require('chatora').search()
  end, { buffer = bufnr, nowait = true, silent = true })

  codeblock.attach(bufnr)
  images.attach(bufnr, project)
  pads.attach(bufnr)
  require('chatora.render').attach(bufnr)
  require('chatora.completion').attach(bufnr)
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
  -- Cosense indentation: 1 whitespace char = 1 level. Make >> / <C-t> / Tab
  -- shift by one space, and keep tabs narrow when a page contains them.
  vim.bo[bufnr].expandtab = true
  vim.bo[bufnr].shiftwidth = 1
  vim.bo[bufnr].softtabstop = 1
  vim.bo[bufnr].tabstop = 2

  lsp.request_ok('chatora/openPage', { project = project, title = title }, function(result)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    set_content(bufnr, result.text)
    finalize_buffer(bufnr, project, title)
  end)
end

local function handle_write(ev)
  local bufnr = ev.buf
  local uri_str = vim.api.nvim_buf_get_name(bufnr)

  lsp.request('chatora/savePage', { uri = uri_str }, function(err, result)
    if err then
      local msg = type(err) == 'table' and (err.message or vim.inspect(err)) or tostring(err)
      vim.notify('[chatora] ' .. msg, vim.log.levels.ERROR)
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    if not result or result.ok == false then
      local code = result and result.code
      if code == 'notFastForward' then
        vim.notify(
          '[chatora] リモートが更新されています。:e で再読込してから保存してください',
          vim.log.levels.WARN
        )
      else
        vim.notify('[chatora] ' .. ((result and result.message) or 'save failed'), vim.log.levels.ERROR)
      end
      return
    end

    if result.text then
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

    vim.bo[bufnr].modified = false
    -- The modified flag just flipped without any text change, so no autocmd or
    -- on_lines fires — refresh the sidebar's ● mark explicitly.
    refresh_sidebar_marks()

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
      return
    end

    vim.notify('[chatora] saved', vim.log.levels.INFO)
  end)
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

-- :q on a window showing an unsaved page just hides the buffer ('hidden'):
-- warn so the change isn't forgotten. Neovim itself still hard-blocks
-- non-bang :qa/:q while any modified buffer exists.
vim.api.nvim_create_autocmd('QuitPre', {
  group = augroup,
  pattern = 'cosense://*',
  callback = function(ev)
    if vim.bo[ev.buf].modified then
      local _, title = uri.parse(vim.api.nvim_buf_get_name(ev.buf))
      vim.notify(
        '[chatora] 未保存の変更があります: ' .. (title or '?') .. '（バッファは残っています。:w で保存できます）',
        vim.log.levels.WARN
      )
    end
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
function M.open(project, title, target_win)
  if target_win and vim.api.nvim_win_is_valid(target_win) then
    vim.api.nvim_set_current_win(target_win)
  end
  local uri_str = uri.format(project, title)
  -- magic.file=false: the URI contains %XX escapes that :edit would otherwise
  -- expand as the "current file" special character (E499 on Japanese titles).
  vim.cmd({ cmd = 'edit', args = { uri_str }, magic = { file = false } })
end

return M
