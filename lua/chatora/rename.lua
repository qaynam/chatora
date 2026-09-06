-- Renaming a page is editing its title line, as on the web. The rename is settled when the
-- cursor leaves line 1 (or on :w): the reader answers the web's questions first, and only
-- then does the title reach the server. Until then a save carries the old title.
local M = {}

local uri = require('chatora.uri')
local lsp = require('chatora.lsp')

local REQUEST_TIMEOUT_MS = 15000

local function typed_title(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ''
end

--- True while line 1 says a title the server does not have (`chatora_title`).
function M.pending(bufnr)
  local known = vim.b[bufnr].chatora_title
  if known == nil or vim.b[bufnr].chatora_untitled then
    return false
  end
  local typed = typed_title(bufnr)
  return typed ~= known and vim.trim(typed) ~= ''
end

--- Move the page into the page titled `into` and show that page. False when the server
--- refused, with the buffer left as it was.
function M.merge(bufnr, into)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local project, title = uri.parse(name)
  local result = lsp.request_wait('chatora/mergePage', { uri = name, into = into }, REQUEST_TIMEOUT_MS)
  if not result or result.ok == false then
    vim.notify(
      '[chatora] 統合できませんでした: ' .. ((result and result.message) or 'サーバーが応答しません'),
      vim.log.levels.ERROR
    )
    return false
  end
  vim.notify(
    ('[chatora] 「%s」を「%s」に統合しました（%d 行を末尾に足しました）'):format(
      title,
      result.title,
      result.appended or 0
    )
  )
  local target_uri = uri.format(project, result.title)
  local winid = vim.fn.bufwinid(bufnr)
  vim.bo[bufnr].modified = false
  -- Deferred: inside the buffer's own BufWriteCmd, deleting it is E203 and :edit fires no
  -- BufReadCmd (autocommands do not nest by default).
  vim.schedule(function()
    -- A buffer already holding the target is behind by exactly the merge; a sync brings it in.
    local existing = vim.fn.bufnr(target_uri)
    if winid ~= -1 and vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_call(winid, function()
        -- magic.file=false: the URI's %XX escapes would otherwise expand as the "current file".
        vim.cmd({ cmd = 'edit', args = { target_uri }, magic = { file = false } })
      end)
    end
    if existing ~= -1 then
      require('chatora.sync').run(existing)
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)
  return true
end

--- Whether the links that name `from` should follow the page to `to`; nil when the reader
--- backed out. A page nothing links to is not asked.
local function ask_link_rewrite(bufnr, from, to)
  local meta = vim.b[bufnr].chatora_meta
  local linked = meta and tonumber(meta.linked) or 0
  if linked <= 0 then
    return false
  end
  local choice = vim.fn.confirm(
    ('%d 個のページが「%s」にリンクしています。リンクも「%s」に書き換えますか？'):format(linked, from, to),
    '書き換える(&Y)\n書き換えない(&N)',
    1,
    'Question'
  )
  if choice == 1 then
    return true
  end
  if choice == 2 then
    return false
  end
  return nil
end

--- What a save of a changed title should do: 'save' (and whether the links that named the
--- old title should follow), 'done' when the page was merged away, 'cancel'.
function M.resolve(bufnr)
  if not M.pending(bufnr) then
    return 'save', false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local title = typed_title(bufnr)
  local check = lsp.request_wait('chatora/titleTaken', { uri = name, title = title }, REQUEST_TIMEOUT_MS)
  if not check or check.ok == false then
    vim.notify(
      '[chatora] タイトルを確かめられませんでした: '
        .. ((check and check.message) or 'サーバーが応答しません'),
      vim.log.levels.ERROR
    )
    return 'cancel'
  end
  if check.taken then
    local existing = check.title or title
    local choice = vim.fn.confirm(
      ('「%s」というページは既にあります。'):format(existing),
      '統合する(&M)\n別の名前で保存する（末尾に番号が付きます）(&S)\nやめる(&C)',
      3,
      'Question'
    )
    if choice == 1 then
      return M.merge(bufnr, existing) and 'done' or 'cancel'
    end
    if choice ~= 2 then
      return 'cancel'
    end
  end
  local rewrite = ask_link_rewrite(bufnr, vim.b[bufnr].chatora_title, title)
  if rewrite == nil then
    return 'cancel'
  end
  return 'save', rewrite
end

--- Point every link in the project that named `from` at `to`.
function M.rewrite_links(project, from, to)
  lsp.request('chatora/replaceLinks', { project = project, from = from, to = to }, function(err, result)
    if err or not result or result.ok == false then
      vim.notify(
        '[chatora] リンクを書き換えられませんでした: '
          .. ((result and result.message) or (err and tostring(err)) or ''),
        vim.log.levels.ERROR
      )
      return
    end
    if result.pages then
      vim.notify(('[chatora] %d ページのリンクを「%s」に書き換えました'):format(result.pages, to))
    else
      vim.notify('[chatora] ' .. (result.message or 'リンクを書き換えました'))
    end
  end)
end

--- Settle a pending rename once the cursor has left the title line. A title the reader
--- backed out of, or whose save failed, waits for the next edit to it or an explicit :w.
function M.settle(bufnr)
  if not M.pending(bufnr) then
    return
  end
  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 or vim.api.nvim_win_get_cursor(winid)[1] == 1 then
    return
  end
  local typed = typed_title(bufnr)
  if vim.b[bufnr].chatora_rename_held == typed or require('chatora.status').get(bufnr) == 'saving' then
    return
  end
  vim.b[bufnr].chatora_rename_held = typed
  require('chatora.page').save(bufnr)
end

local augroup = vim.api.nvim_create_augroup('ChatoraRename', { clear = true })

function M.attach(bufnr)
  vim.api.nvim_clear_autocmds({ group = augroup, buffer = bufnr })
  -- InsertLeave too: Enter at the end of the title leaves it in insert mode, where
  -- CursorMoved does not fire.
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'InsertLeave' }, {
    group = augroup,
    buffer = bufnr,
    callback = function()
      M.settle(bufnr)
    end,
  })
end

return M
