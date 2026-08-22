-- BufReadCmd/BufWriteCmd for cosense://<project>/<encoded title> buffers.
local M = {}

local uri = require('chatora.uri')
local lsp = require('chatora.lsp')
local related = require('chatora.related')

--- Replace buffer content without polluting undo history.
local function set_content(bufnr, text)
  local lines = vim.split(text or '', '\n', { plain = true })
  local ul = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].undolevels = ul
end

local function finalize_buffer(bufnr, project, title)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.bo[bufnr].filetype = 'cosense'
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modified = false
  lsp.ensure_start(bufnr)
  related.on_page_opened(project, title)
  vim.keymap.set('n', 'gR', function()
    related.toggle()
  end, { buffer = bufnr, nowait = true, silent = true })
end

local function handle_read(ev)
  local project, title = uri.parse(ev.match)
  if not project or not title then
    vim.notify('[chatora] invalid cosense uri: ' .. ev.match, vim.log.levels.ERROR)
    return
  end

  local bufnr = ev.buf
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

    if result.titleChanged then
      local project = uri.parse(uri_str)
      local new_uri = uri.format(project, result.titleChanged.to)
      pcall(vim.api.nvim_buf_set_name, bufnr, new_uri)
      vim.notify(
        '[chatora] title changed: ' .. result.titleChanged.from .. ' -> ' .. result.titleChanged.to,
        vim.log.levels.INFO
      )
    end

    vim.bo[bufnr].modified = false
    vim.notify('[chatora] saved', vim.log.levels.INFO)
  end)
end

local augroup = vim.api.nvim_create_augroup('ChatoraPage', { clear = true })
vim.api.nvim_create_autocmd('BufReadCmd', { group = augroup, pattern = 'cosense://*', callback = handle_read })
vim.api.nvim_create_autocmd('BufWriteCmd', { group = augroup, pattern = 'cosense://*', callback = handle_write })

--- Open project/title (edits the cosense:// URI), optionally in target_win.
function M.open(project, title, target_win)
  if target_win and vim.api.nvim_win_is_valid(target_win) then
    vim.api.nvim_set_current_win(target_win)
  end
  local uri_str = uri.format(project, title)
  vim.cmd({ cmd = 'edit', args = { uri_str } })
end

return M
