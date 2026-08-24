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
  '   :Chatora project       プロジェクトを切り替え',
  '   :Chatora account       アカウントを切り替え / 追加（複数 PAT 対応）',
  '   :Chatora logout        ログアウト（Keychain から PAT を削除）',
  '   :Chatora help          このヘルプ',
  '',
  ' 検索（インクリメンタル）',
  '   タイプするたびに絞り込み。<C-n>/<C-p> or ↑↓ 選択移動、<CR> 開く、<Esc> 閉じる',
  '   空欄のときは最近更新されたページを表示',
  '',
  ' サイドバー',
  '   <CR> ページを開く   R 再読込   s 検索   n 新規   P プロジェクト切替   q 閉じる',
  '   ● = 未保存の変更があるページ（スクロールで続きを自動読込）',
  '',
  ' ページバッファ',
  '   :w / :wq  保存（同期。:wq 一回で保存して閉じる）',
  '   gR   関連ページパネルをトグル',
  '   gd   リンク先ページへジャンプ / 外部 URL は確認してブラウザで開く',
  '   gs   検索',
  '   [ / #  でリンク・ハッシュタグ補完（[ は自動で ] を補う）',
  '   <C-t>  日時を挿入   <C-i>  自分のアイコンを挿入（insert モード）',
  '   テーブルは table:名前 + インデント行、セルは Tab 区切り',
  '   （テーブル行の中では Tab キーが本物のタブを入力する）',
  '   保存状態は ✓/●/◍/✗ アイコンで表示（statusline 連携は README 参照）',
  '   :q   閉じてもバッファは残る（未保存なら警告。:qa は未保存があると止まる）',
  '   画像表示（アイコン記法・画像リンク）には 3rd/image.nvim（推奨）か',
  '   snacks.nvim の image + グラフィック対応ターミナル（kitty/ghostty）が必要',
  '',
  ' 設定オプション（setup、抜粋）',
  '   autosave = 3            -- 編集が止まって 3 秒後に自動保存（既定 false）',
  '   pads = false            -- 箇条書きの ● / ┃ 表示を無効化（既定 true）',
  '   tables = false          -- table: ブロックの罫線描画を無効化（既定 true）',
  '   related_auto_open = false -- 関連ページパネルの自動表示を止める（既定 true）',
  '   external_link = "open"  -- gd で確認なしにブラウザを開く（既定 "confirm"）',
  '   image_border = false    -- 画像上下の罫線を消す（既定 true）',
  '   keymaps = false         -- <C-t>/<C-i>/[ ペアを無効化（既定 true）',
  '',
  ' 関連ページパネル（既定で自動表示。q で閉じると次の gR まで出ない）',
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
    vim.keymap.set('n', key, close, { buffer = buf, nowait = true, silent = true, desc = 'chatora: ヘルプを閉じる' })
  end
end

return M
