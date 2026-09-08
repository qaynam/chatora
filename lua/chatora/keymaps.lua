-- Every key chatora maps, in one table: the <prefix> namespace, and the normal- and
-- insert-mode keys of a page buffer. Each stands for an action of `chatora.actions`, which
-- a `<Plug>(chatora-…)` mapping reaches as well, so a reader who maps their own keys needs
-- nothing from here. Cosense's insert-mode habits reproduced in page buffers — tab-separated
-- table cells, bracket auto-pairing — are behaviours (`edit`), not keys, and live here only
-- because a mapping is how they are done.
local M = {}

local config = require('chatora.config')
local lsp = require('chatora.lsp')

local function as_list(value)
  return type(value) == 'table' and value or { value }
end

local DEFAULT_PREFIX = '<leader>c'

--- Every action, in the order the help sheet lists them. A default written `<prefix>x`
--- hangs off `keymaps.prefix`; `page` and `insert` actions are mapped per page buffer.
---@type { name: string, keys: string|string[], desc: string, scope: 'global'|'page'|'insert' }[]
local ACTIONS = {
  { name = 'sidebar', keys = '<prefix>t', desc = 'サイドバーを開閉', scope = 'global' },
  { name = 'search', keys = '<prefix>s', desc = 'ページを検索', scope = 'global' },
  { name = 'new', keys = '<prefix>n', desc = '新規ページ', scope = 'global' },
  { name = 'project', keys = '<prefix>p', desc = 'プロジェクト切り替え', scope = 'global' },
  { name = 'account', keys = '<prefix>a', desc = 'アカウント切り替え', scope = 'global' },
  { name = 'help', keys = '<prefix>?', desc = 'ヘルプ', scope = 'global' },
  { name = 'follow', keys = 'gd', desc = 'リンク先へジャンプ（外部 URL はブラウザで開く）', scope = 'page' },
  { name = 'related', keys = { '<prefix>r', 'gR' }, desc = '関連ページパネルを開閉', scope = 'page' },
  { name = 'related_side', keys = '<prefix>R', desc = '関連ページパネルを下／右に切り替え', scope = 'page' },
  { name = 'info', keys = '<prefix>i', desc = 'ページ情報（作成者・更新者・被リンクなど）', scope = 'page' },
  { name = 'pull', keys = '<prefix>f', desc = 'サーバーの変更を取り込む（マージ）', scope = 'page' },
  { name = 'next_conflict', keys = { '<prefix>c', ']c' }, desc = '次の競合へ', scope = 'page' },
  { name = 'next_updated', keys = ']u', desc = '次の更新行へ', scope = 'page' },
  { name = 'prev_updated', keys = '[u', desc = '前の更新行へ', scope = 'page' },
  { name = 'paste_image', keys = '<prefix>v', desc = 'クリップボードの画像を貼り付け', scope = 'page' },
  { name = 'delete', keys = '<prefix>d', desc = 'ページを削除（確認あり）', scope = 'page' },
  { name = 'normalize_indent', keys = '<prefix>I', desc = 'インデントを半角スペースに揃える', scope = 'page' },
  { name = 'copy_url', keys = '<prefix>y', desc = 'ページ URL をコピー', scope = 'page' },
  { name = 'copy_link', keys = '<prefix>Y', desc = 'リンク記法をコピー', scope = 'page' },
  { name = 'open_in_browser', keys = '<prefix>o', desc = 'ブラウザで開く', scope = 'page' },
  { name = 'insert_date', keys = '<C-t>', desc = '日時を挿入', scope = 'insert' },
  {
    name = 'insert_icon',
    keys = { '<C-i>', '<M-i>' },
    desc = 'アイコンを挿入（リンク補完中はその候補のアイコン）',
    scope = 'insert',
  },
}

local KNOWN_KEYS = { prefix = true }
for _, action in ipairs(ACTIONS) do
  KNOWN_KEYS[action.name] = true
end

-- What v0.1 kept in this table under another name, or as a behaviour that is now `edit`'s.
-- Named in the warning only; the old key does nothing.
local RENAMED = {
  toggle = 'keymaps.sidebar',
  autopair = 'edit.autopair',
  table_tab = 'edit.table_tab',
  date_format = 'edit.date_format',
}

--- Each action's keys as configured, or nil for `keymaps = false`. An action set to
--- `false` has none. A name not in the table is called out once: misspelled, it would
--- leave the default in place without a word.
local function resolve()
  local raw = config.options.keymaps
  if raw == false then
    return nil
  end
  if type(raw) ~= 'table' then
    raw = {}
  end
  for key in pairs(raw) do
    if not KNOWN_KEYS[key] then
      vim.notify_once(
        ('[chatora] keymaps に知らないキー `%s` があります%s'):format(
          key,
          RENAMED[key] and ('（`' .. RENAMED[key] .. '` になりました）') or ''
        ),
        vim.log.levels.WARN
      )
    end
  end
  local prefix = raw.prefix
  if prefix == nil then
    prefix = DEFAULT_PREFIX
  end
  local out = {}
  for _, action in ipairs(ACTIONS) do
    local given = raw[action.name]
    local keys = {}
    if given == nil then
      keys = as_list(action.keys)
    elseif given ~= false then
      keys = as_list(given)
    end
    local expanded = {}
    for _, key in ipairs(keys) do
      if key:find('<prefix>', 1, true) then
        if prefix then
          expanded[#expanded + 1] = (key:gsub('<prefix>', (prefix:gsub('%%', '%%%%'))))
        end
      else
        expanded[#expanded + 1] = key
      end
    end
    out[action.name] = expanded
  end
  return out
end

local function run(name)
  require('chatora.actions')[name]()
end

--- The `<Plug>` mapping standing for `name`: underscores become hyphens, as `<Plug>` names
--- customarily do.
function M.plug(name)
  return '<Plug>(chatora-' .. name:gsub('_', '-') .. ')'
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

--- Insert the date and time, in `edit.date_format`, at the cursor.
function M.insert_date()
  insert_at_cursor(vim.api.nvim_get_current_buf(), os.date(config.options.edit.date_format))
end

--- Insert an icon notation. Which icon depends on what is on screen: with a link
--- completion open and an entry highlighted it is *that page's* icon, replacing the
--- half-typed `[...]` outright — the same thing the web editor does when the key is pressed
--- with a suggestion focused. With no menu it falls back to the user's own icon.
function M.insert_icon()
  local bufnr = vim.api.nvim_get_current_buf()
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
local function tab_map(bufnr)
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
  -- completion fire: the server only completes inside a *closed* pair. Only at the end of
  -- the line, though, as on the web: a `[` typed in front of text is opening a link around
  -- it, and a `]` dropped there would split what follows.
  vim.keymap.set('i', '[', function()
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    if line:sub(col + 1):find('%S') then
      return '['
    end
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

--- Map the page and insert actions in a page buffer, and install the `edit` behaviours
--- that are done with a mapping.
function M.attach(bufnr)
  local keys = resolve()
  if keys then
    for _, action in ipairs(ACTIONS) do
      if action.scope ~= 'global' then
        local mode = action.scope == 'insert' and 'i' or 'n'
        for _, key in ipairs(keys[action.name]) do
          vim.keymap.set(mode, key, function()
            run(action.name)
          end, { buffer = bufnr, nowait = mode == 'n', silent = true, desc = 'chatora: ' .. action.desc })
        end
      end
    end
    if #keys.insert_icon > 0 then
      -- Warm the cache so the first press inserts immediately instead of after a
      -- round-trip.
      with_own_name(function() end, { silent = true })
    end
  end

  local edit = config.options.edit
  if edit.table_tab then
    -- Also on InsertEnter: completion plugins map <Tab> per buffer when insert mode starts,
    -- so a mapping set at buffer-load time is already displaced by the first keystroke.
    tab_map(bufnr)
    vim.api.nvim_create_autocmd('InsertEnter', {
      buffer = bufnr,
      group = vim.api.nvim_create_augroup('ChatoraKeymaps' .. bufnr, { clear = true }),
      callback = function()
        tab_map(bufnr)
      end,
    })
  end
  if edit.autopair then
    autopair_maps(bufnr)
  end
end

--- Define a `<Plug>` mapping for every action, and map the global ones. These are the
--- only mappings chatora sets outside a page buffer. Whatever an earlier setup() mapped
--- goes first, so a reload with other keys leaves no stale ones behind.
function M.setup_global()
  for _, mode in ipairs({ 'n', 'i' }) do
    for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
      if map.desc and map.desc:find('^chatora: ') then
        pcall(vim.keymap.del, mode, map.lhs)
      end
    end
  end
  for _, action in ipairs(ACTIONS) do
    vim.keymap.set(action.scope == 'insert' and 'i' or 'n', M.plug(action.name), function()
      run(action.name)
    end, { desc = 'chatora: ' .. action.desc })
  end
  local keys = resolve()
  if not keys then
    return
  end
  for _, action in ipairs(ACTIONS) do
    if action.scope == 'global' then
      for _, key in ipairs(keys[action.name]) do
        vim.keymap.set('n', key, function()
          run(action.name)
        end, { silent = true, desc = 'chatora: ' .. action.desc })
      end
    end
  end
end

--- The configured keys of one scope as { keys, description } rows, in the table's order,
--- for the help sheet. Only actions with a key are listed.
---@param scope 'global'|'page'|'insert'
function M.rows(scope)
  local keys = resolve()
  local rows = {}
  if not keys then
    return rows
  end
  for _, action in ipairs(ACTIONS) do
    if action.scope == scope and #keys[action.name] > 0 then
      rows[#rows + 1] = { table.concat(keys[action.name], ' / '), action.desc }
    end
  end
  return rows
end

--- The action names, in the help sheet's order.
function M.action_names()
  return vim.tbl_map(function(action)
    return action.name
  end, ACTIONS)
end

return M
