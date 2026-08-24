-- Cosense's own insert-mode editing shortcuts, reproduced in page buffers:
-- timestamp insertion, self-icon insertion, tab-separated table cells, and
-- bracket auto-pairing. Plus the one global mapping chatora installs, for
-- toggling the sidebar.
local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')

local DEFAULTS = {
  insert_date = '<C-t>',
  insert_icon = '<C-i>',
  date_format = '%Y-%m-%d %H:%M:%S',
  autopair = true,
  table_tab = true,
  toggle_sidebar = '<leader>ct',
}

local function settings()
  local raw = config.options.keymaps
  if raw == false then
    return nil
  end
  if type(raw) ~= 'table' then
    raw = {}
  end
  local out = {}
  for key, fallback in pairs(DEFAULTS) do
    -- `false` disables one mapping; only a missing key falls back to the default.
    out[key] = raw[key] == nil and fallback or raw[key]
  end
  return out
end

-- Resolved once per session from chatora/authStatus; the icon notation needs
-- the account's own `name`, not its display name.
local own_name = nil

--- Drop the cached name. Account switching changes whose icon <C-i> inserts,
--- so init.switch_account calls this after a successful switch.
function M.invalidate_account_cache()
  own_name = nil
end

local function with_own_name(cb, opts)
  if own_name then
    cb(own_name)
    return
  end
  lsp.request_ok('chatora/authStatus', {}, function(result)
    local user = result.user or {}
    if not user.name or user.name == '' then
      if not (opts and opts.silent) then
        vim.notify('[chatora] アイコンを挿入できません（ログイン情報が取得できませんでした）', vim.log.levels.WARN)
      end
      return
    end
    own_name = user.name
    cb(own_name)
  end)
end

--- Insert `text` at the cursor, leaving the cursor after it. Guarded on bufnr
--- because the icon lookup can resolve a round-trip later, by which point the
--- user may have moved to another buffer.
local function insert_at_cursor(bufnr, text)
  if vim.api.nvim_get_current_buf() ~= bufnr then
    return
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, { text })
  vim.api.nvim_win_set_cursor(0, { row, col + #text })
end

local function char_at(line, col)
  return line:sub(col + 1, col + 1)
end

--- True when the 0-based `row` is a body row of some table block.
local function in_table_row(bufnr, row)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, block in ipairs(require('chatora.table').find_blocks(lines)) do
    if row >= block.start_line and row < block.end_line then
      return true
    end
  end
  return false
end

--- <C-i> and <Tab> are the same byte unless the terminal speaks the kitty
--- keyboard protocol, so one handler serves both and picks by cursor position.
--- A table row needs a *real* tab: page buffers use expandtab, so a plain Tab
--- would type a space and the row would parse as a single cell.
local function tab_map(bufnr, opts)
  vim.keymap.set('i', '<Tab>', function()
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = vim.api.nvim_get_current_line()
    local indent = #(line:match('^%s*'))
    if col <= indent then
      return '<Tab>'
    end
    if opts.table_tab and in_table_row(bufnr, row - 1) then
      return '<C-v><Tab>'
    end
    if opts.insert_icon then
      vim.schedule(function()
        with_own_name(function(name)
          insert_at_cursor(bufnr, '[' .. name .. '.icon]')
        end)
      end)
      return ''
    end
    return '<Tab>'
  end, {
    buffer = bufnr,
    expr = true,
    silent = true,
    desc = 'chatora: テーブル内はタブ / 行頭はインデント / それ以外はアイコン',
  })
end

local function autopair_maps(bufnr)
  local function opts(desc)
    return { buffer = bufnr, expr = true, silent = true, desc = desc }
  end

  -- Cosense inserts the closing bracket for you, which is also what makes link
  -- completion fire: the server only completes inside a *closed* pair.
  vim.keymap.set('i', '[', function()
    return '[]<Left>'
  end, opts('chatora: [] を自動ペア'))

  vim.keymap.set('i', ']', function()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    if char_at(vim.api.nvim_get_current_line(), col) == ']' then
      return '<Right>'
    end
    return ']'
  end, opts('chatora: 閉じ ] をスキップ'))

  vim.keymap.set('i', '<BS>', function()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    if col > 0 and char_at(line, col - 1) == '[' and char_at(line, col) == ']' then
      return '<BS><Del>'
    end
    return '<BS>'
  end, opts('chatora: 空の [] をまとめて削除'))
end

--- Install the insert-mode shortcuts on a cosense page buffer.
function M.attach(bufnr)
  local opts = settings()
  if not opts then
    return
  end

  if opts.insert_date then
    vim.keymap.set('i', opts.insert_date, function()
      insert_at_cursor(bufnr, os.date(opts.date_format))
    end, { buffer = bufnr, silent = true, desc = 'chatora: 日時を挿入' })
  end

  if opts.insert_icon then
    -- Warm the cache so the first press inserts immediately instead of after a
    -- round-trip.
    with_own_name(function() end, { silent = true })
    vim.keymap.set('i', opts.insert_icon, function()
      with_own_name(function(name)
        insert_at_cursor(bufnr, '[' .. name .. '.icon]')
      end)
    end, { buffer = bufnr, silent = true, desc = 'chatora: 自分のアイコンを挿入' })
  end

  -- Last, so it wins the byte <C-i> shares with <Tab>.
  tab_map(bufnr, opts)

  if opts.autopair then
    autopair_maps(bufnr)
  end
end

--- The one mapping chatora sets outside a page buffer.
function M.setup_global()
  local opts = settings()
  if not (opts and opts.toggle_sidebar) then
    return
  end
  vim.keymap.set('n', opts.toggle_sidebar, function()
    require('chatora').toggle()
  end, { silent = true, desc = 'chatora: サイドバーを開閉' })
end

return M
