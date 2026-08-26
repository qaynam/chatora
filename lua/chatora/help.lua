-- :Chatora help — a floating cheatsheet.
--
-- Rows are laid out from data, not hand-spaced: the description column is one
-- width for the whole sheet, so adding a longer key can never leave a section
-- silently misaligned.
local M = {}

--- Each section is a title plus rows. A row is { key, description }, or a bare
--- string for a full-width note. `rows = 'global'` stands for the configured
--- <leader>c namespace, which is only known once setup() has run.
local SECTIONS = {
  {
    title = 'コマンド',
    rows = {
      { ':Chatora [open]', 'サイドバーを開く（初回は PAT 認証 → プロジェクト選択）' },
      { ':Chatora <url>', 'Cosense のページ URL を直接開く' },
      { ':Chatora toggle', 'サイドバーを開閉' },
      { ':Chatora new [title]', '新規ページを作成（title 省略された場合は入力プロンプトが表示される）' },
      { ':Chatora search [q]', 'ページを検索（q 省略時は入力プロンプトが表示される）' },
      { ':Chatora related', '関連ページパネルをトグル' },
      { ':Chatora project [name]', 'プロジェクトを切り替え（name を渡すとアカウントも切り替わる）' },
      { ':Chatora account', 'アカウントを切り替え / 追加（複数 PAT 対応）' },
      { ':Chatora logout', 'ログアウト（Keychain から PAT を削除）' },
      { ':Chatora log', '診断ログを開く（log オプションが有効にする必要がある）' },
      { ':Chatora reload', 'nvim を閉じずにプラグインを再読み込み' },
      { ':Chatora help', 'ヘルプを開く' },
    },
  },
  {
    title = 'グローバルキーマップ',
    rows = 'global',
  },
  {
    title = 'サイドバー',
    rows = {
      { '<CR> / l', 'ページを開く' },
      { 'R', '一覧を再読込' },
      { 's', 'ページを検索' },
      { 'n', '新規ページを作成' },
      { 'P', 'プロジェクトを切り替え' },
      { '<Tab> / <S-Tab>', 'タブを切り替え（1..9 とクリックも可）' },
      { 'q', 'サイドバーを閉じる' },
      { '✓ / ●', '保存済み / 未保存' },
      { '▍', '未読（最後に見たあとに更新された）' },
      '既定のタブは「すべて」と「未読」。下端までスクロールすると続きを自動で読み込む。',
    },
  },
  {
    title = 'ページバッファ',
    rows = {
      { ':w / :wq', '保存（同期。:wq 一回で保存して閉じる）' },
      { ':q', '閉じる（未保存なら保存するか確認）' },
      { 'gd', 'リンク先へジャンプ（外部 URL は確認してブラウザで開く）' },
      { 'gR', '関連ページパネルをトグル' },
      { '<leader>cf', 'サーバーの変更を取り込む（マージ。ローカルの内容は消えない）' },
      { ']c', '次の競合行へ' },
      { '<leader>cv', 'クリップボードの画像をアップロードして貼り付け' },
      { 'gs', 'ページを検索' },
      { '[ / #', 'リンク・ハッシュタグを補完（[ は ] を自動で補う）' },
      { '<C-t>', '日時を挿入（insert モード）' },
      { '<C-i> / <M-i>', 'アイコンを挿入。補完で候補を選んでいればその候補のアイコン' },
      { 'v して * _ - /', '選択を [* ] などで囲む（同じキーの連打で [*** ] まで育つ）' },
      { 'v して [', '選択を [ ] で囲んでリンクにする' },
      { '<Tab>', 'テーブル行だけ本物のタブ。他は元のマッピング（補完など）に委譲' },
    },
  },
  {
    title = '検索',
    rows = {
      { 'タイプ', '1 文字ごとに絞り込み（空欄なら最近更新されたページ）' },
      { '<C-n> / <C-p>', '選択を移動（↑↓ も可）' },
      { '<CR>', '選択したページを開く' },
      { '<Esc>', '検索を閉じる' },
    },
  },
  {
    title = '関連ページパネル',
    rows = {
      { '<CR>', 'ページを開く' },
      { 'q', 'パネルを閉じる' },
      { '被リンク N', '各行の右端はそのページの被リンク数（winbar は今開いているページの分）' },
      '既定でページを開くと自動表示。q で閉じると次の gR まで出ない。',
    },
  },
  {
    title = '記法の表示',
    rows = {
      { 'カーソル行', '記法をソースのまま表示（他の行は装飾後の見た目）' },
      { 'table:名前', 'インデントした行がタブ区切りのセルとして罫線描画される' },
      { 'code:名前', 'インデントした行が背景付きでシンタックスハイライトされる' },
      '画像表示には 3rd/image.nvim（推奨）か snacks.nvim の image と、',
      'グラフィック対応ターミナル（kitty / Ghostty）が必要。',
    },
  },
  {
    title = '設定（setup / lazy.nvim の opts、抜粋）',
    rows = {
      { 'autosave = 3', '編集が止まって 3 秒後に自動保存' },
      { 'pads = false', '箇条書きの中点表示をやめる' },
      { 'tables = false', 'table: ブロックの罫線描画をやめる' },
      { 'keymaps = false', '<C-t> / <C-i> / [ の自動ペアをやめる' },
      { 'external_link = "open"', 'gd で確認なしにブラウザを開く' },
      { 'sidebar_poll = false', 'サイドバーの自動更新を止める（既定 60 秒間隔）' },
      { 'sync = false', 'ページの自動同期を止める（既定 30 秒間隔、手動は <leader>cf）' },
      { 'quote = { bar = "┃" }', '引用の縦棒を変える（false で無効）' },
      { 'notations = {...}', '独自の [記号 本文] 記法を定義する' },
      '全オプションと statusline 連携は README を参照。',
    },
  },
}

local INDENT = '  '
local GAP = '  '

local function rows_of(section)
  if section.rows == 'global' then
    return require('chatora.keymaps').global_rows()
  end
  return section.rows
end

local function key_column_width(sections)
  local width = 0
  for _, section in ipairs(sections) do
    for _, row in ipairs(rows_of(section)) do
      if type(row) == 'table' then
        width = math.max(width, vim.fn.strdisplaywidth(row[1]))
      end
    end
  end
  return width
end

local function build_lines()
  local width = key_column_width(SECTIONS)
  local lines = { ' chatora 🐈' }
  for _, section in ipairs(SECTIONS) do
    lines[#lines + 1] = ''
    lines[#lines + 1] = ' ' .. section.title
    for _, row in ipairs(rows_of(section)) do
      if type(row) == 'string' then
        lines[#lines + 1] = INDENT .. row
      else
        local pad = string.rep(' ', width - vim.fn.strdisplaywidth(row[1]))
        lines[#lines + 1] = INDENT .. row[1] .. pad .. GAP .. row[2]
      end
    end
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = ' q / <Esc> で閉じる'
  return lines
end

function M.open()
  local lines = build_lines()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'chatora_help'

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)

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
