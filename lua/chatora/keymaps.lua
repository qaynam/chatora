-- Cosense's own insert-mode editing shortcuts, reproduced in page buffers:
-- timestamp insertion, self-icon insertion, tab-separated table cells, and
-- bracket auto-pairing. Plus the <leader>c namespace, which is every chatora
-- mapping that lives outside a page buffer.
local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')

local function as_list(value)
  return type(value) == 'table' and value or { value }
end

local DEFAULTS = {
  insert_date = '<C-t>',
  -- <C-i> is Cosense's own shortcut, but a terminal only sends it as a distinct key when
  -- it speaks the kitty keyboard protocol (kitty/Ghostty natively; tmux needs
  -- `set -g extended-keys on`). Everywhere else it arrives as <Tab>, which the completion
  -- plugin owns — hence the <M-i> alternative, which nothing contends for.
  insert_icon = { '<C-i>', '<M-i>' },
  date_format = '%Y-%m-%d %H:%M:%S',
  autopair = true,
  table_tab = true,
  prefix = '<leader>c',
}

-- The <leader>c namespace, as suffix -> { action, description }. `prefix = false`
-- installs none of them; a suffix set to `false` drops just that one.
local GLOBAL_ACTIONS = {
  t = { 'toggle', 'サイドバーを開閉' },
  s = { 'search', 'ページを検索' },
  n = { 'new', '新規ページ' },
  r = { 'related', '関連ページを開閉' },
  R = { 'related_side', '関連ページを下／右に切り替え' },
  i = { 'info', 'ページ情報（作成者・更新者・被リンクなど）' },
  f = { 'pull', 'サーバーの変更を取り込む（マージ）' },
  c = { 'next_conflict', '次の競合へ' },
  v = { 'paste_image', 'クリップボードの画像を貼り付け' },
  d = { 'delete', 'ページを削除（確認あり）' },
  I = { 'normalize_indent', 'インデントを半角スペースに揃える' },
  y = { 'copy_url', 'ページ URL をコピー' },
  Y = { 'copy_link', 'リンク記法をコピー' },
  o = { 'open_in_browser', 'ブラウザで開く' },
  a = { 'account', 'アカウント切り替え' },
  p = { 'project', 'プロジェクト切り替え' },
  ['?'] = { 'help', 'ヘルプ' },
}

local function run(action)
  local actions = require('chatora.actions')
  if actions[action] then
    actions[action]()
  else
    require('chatora').dispatch(action, '')
  end
end

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

--- Insert an icon notation. Which icon depends on what is on screen: with a link
--- completion open and an entry highlighted it is *that page's* icon, replacing the
--- half-typed `[...]` outright — the same thing the web editor does when the key is pressed
--- with a suggestion focused. With no menu it falls back to the user's own icon.
local function insert_icon(bufnr)
  local completion = require('chatora.completion')
  local title = completion.selected_title()
  if title then
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local open, close = completion.link_range(vim.api.nvim_get_current_line(), col)
    if open then
      -- Dismissed first: an open menu treats the replacement as more typing and re-filters
      -- against text that is no longer a query.
      completion.dismiss()
      local text = '[' .. title .. '.icon]'
      vim.api.nvim_buf_set_text(bufnr, row - 1, open - 1, row - 1, close, { text })
      vim.api.nvim_win_set_cursor(0, { row, open - 1 + #text })
      return
    end
  end
  with_own_name(function(name)
    insert_at_cursor(bufnr, '[' .. name .. '.icon]')
  end)
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

local TAB_DESC = 'chatora: テーブル行だけ本物のタブ（他は元のマッピングに委譲）'

--- The `<Tab>` mapping chatora is about to displace. nil when nothing claims the key, and
--- when chatora's own mapping is the one in place — re-attaching must not make chatora
--- delegate to itself.
local function foreign_tab_map()
  local map = vim.fn.maparg('<Tab>', 'i', false, true)
  if vim.tbl_isempty(map) or map.desc == TAB_DESC then
    return nil
  end
  return map
end

--- Hand `<Tab>` back to whoever had it. Feeding the resolved keys (rather than calling
--- through) keeps an expr mapping's result going through Neovim's own key handling, which
--- is what a completion plugin expects to happen on the key it mapped.
local function replay_tab(map)
  local keys = map.rhs
  if map.callback then
    local ok, produced = pcall(map.callback)
    if not ok then
      return
    end
    -- A non-expr callback did its own work and has nothing left to feed.
    if map.expr ~= 1 then
      return
    end
    keys = produced
  end
  if type(keys) ~= 'string' or keys == '' then
    return
  end
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes(keys, true, true, true),
    map.noremap == 1 and 'n' or 'm',
    false
  )
end

--- Claim `<Tab>` only inside a table row, where it must insert a *real* tab: page buffers
--- use expandtab, so a plain Tab would type a space and the row would parse as one cell.
--- Every other keystroke goes back to the mapping chatora displaced — `<Tab>` belongs to
--- the completion plugin, and taking it outright is what made <C-i> stop working.
local function tab_map(bufnr, opts)
  if not opts.table_tab then
    return
  end
  local displaced = foreign_tab_map()
  vim.keymap.set('i', '<Tab>', function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if in_table_row(bufnr, row - 1) then
      return vim.api.nvim_replace_termcodes('<C-v><Tab>', true, true, true)
    end
    if displaced then
      replay_tab(displaced)
      return ''
    end
    return vim.api.nvim_replace_termcodes('<Tab>', true, true, true)
  end, { buffer = bufnr, expr = true, silent = true, desc = TAB_DESC })
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
    for _, key in ipairs(as_list(opts.insert_icon)) do
      vim.keymap.set('i', key, function()
        insert_icon(bufnr)
      end, {
        buffer = bufnr,
        silent = true,
        desc = 'chatora: アイコンを挿入（リンク補完中はその候補のアイコン）',
      })
    end
  end

  -- Also on InsertEnter: completion plugins map <Tab> per buffer when insert mode starts,
  -- so a mapping set at buffer-load time is already displaced by the first keystroke.
  tab_map(bufnr, opts)
  vim.api.nvim_create_autocmd('InsertEnter', {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup('ChatoraKeymaps' .. bufnr, { clear = true }),
    callback = function()
      tab_map(bufnr, opts)
    end,
  })

  if opts.autopair then
    autopair_maps(bufnr)
  end
end

--- Install the global <prefix> namespace. These are the only mappings chatora sets
--- outside a page buffer.
function M.setup_global()
  local opts = settings()
  if not (opts and opts.prefix) then
    return
  end
  local overrides = type(config.options.keymaps) == 'table' and config.options.keymaps or {}
  for suffix, spec in pairs(GLOBAL_ACTIONS) do
    local key = overrides[spec[1]]
    if key == nil then
      key = opts.prefix .. suffix
    end
    if key then
      vim.keymap.set('n', key, function()
        run(spec[1])
      end, { silent = true, desc = 'chatora: ' .. spec[2] })
    end
  end
end

--- The global namespace as { key, description } rows, for the help sheet.
function M.global_rows()
  local opts = settings()
  if not (opts and opts.prefix) then
    return {}
  end
  local overrides = type(config.options.keymaps) == 'table' and config.options.keymaps or {}
  local rows = {}
  for suffix, spec in pairs(GLOBAL_ACTIONS) do
    local key = overrides[spec[1]]
    if key == nil then
      key = opts.prefix .. suffix
    end
    if key then
      rows[#rows + 1] = { key, spec[2] }
    end
  end
  table.sort(rows, function(a, b)
    return a[1] < b[1]
  end)
  return rows
end

return M
