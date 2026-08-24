-- Cosense's own insert-mode editing shortcuts, reproduced in page buffers:
-- timestamp insertion, self-icon insertion, and bracket auto-pairing.
--
-- <C-i> and <Tab> are the same byte in a terminal; Neovim can only tell them
-- apart when the terminal speaks the kitty keyboard protocol (kitty, Ghostty,
-- WezTerm). Elsewhere this mapping also fires on <Tab>, so it is opt-out via
-- `keymaps = { insert_icon = false }`.
local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')

local DEFAULTS = {
  insert_date = '<C-t>',
  insert_icon = '<C-i>',
  date_format = '%Y-%m-%d %H:%M:%S',
  autopair = true,
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

local function autopair_maps(bufnr)
  local opts = { buffer = bufnr, expr = true, silent = true }

  -- Cosense inserts the closing bracket for you, which is also what makes link
  -- completion fire: the server only completes inside a *closed* pair.
  vim.keymap.set('i', '[', function()
    return '[]<Left>'
  end, opts)

  vim.keymap.set('i', ']', function()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    if char_at(vim.api.nvim_get_current_line(), col) == ']' then
      return '<Right>'
    end
    return ']'
  end, opts)

  vim.keymap.set('i', '<BS>', function()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    if col > 0 and char_at(line, col - 1) == '[' and char_at(line, col) == ']' then
      return '<BS><Del>'
    end
    return '<BS>'
  end, opts)
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

  if opts.autopair then
    autopair_maps(bufnr)
  end
end

return M
