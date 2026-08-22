-- :Chatora help — a small floating cheatsheet.
local M = {}

local LINES = {
  ' chatora 🐈',
  '',
  ' コマンド',
  '   :Chatora [open]        サイドバーを開く（初回は PAT 認証 → プロジェクト選択）',
  '   :Chatora new [title]   新規ページを作成（title 省略時は入力プロンプト）',
  '   :Chatora search [q]    ページ検索（q 省略時は入力プロンプト）',
  '   :Chatora related       関連ページパネル（1-hop / 2-hop）をトグル',
  '   :Chatora logout        ログアウト（Keychain から PAT を削除）',
  '   :Chatora help          このヘルプ',
  '',
  ' サイドバー',
  '   <CR> ページを開く   R 再読込   s 検索   n 新規ページ   q 閉じる',
  '   ● = 未保存の変更があるページ',
  '',
  ' ページバッファ',
  '   :w   保存（preview → submit の公式 API）',
  '   gR   関連ページパネルをトグル',
  '   gd   カーソル下のリンク先ページへジャンプ',
  '   gs   検索',
  '   [ / #  でリンク・ハッシュタグ補完',
  '   :q   閉じてもバッファは残る（未保存なら警告。:qa は未保存があると止まる）',
  '',
  ' 関連ページパネル',
  '   <CR> ページを開く   q 閉じる',
  '',
  ' q / <Esc> でこのヘルプを閉じる',
}

function M.open()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, LINES)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'chatora_help'

  local width = 0
  for _, l in ipairs(LINES) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#LINES, vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' chatora help ',
    title_pos = 'center',
  })
  vim.wo[win].cursorline = false

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, close, { buffer = buf, nowait = true, silent = true })
  end
end

return M
