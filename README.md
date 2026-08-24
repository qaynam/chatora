# chatora 🐈

Cosense（旧 Scrapbox）の Neovim クライアント。

- 左サイドバーにページ一覧、右に本物の Neovim エディタ
- `@cosense-toolbox/parser` による記法ハイライト（LSP semantic tokens）
- リンク補完・定義ジャンプ・関連ページ（1-hop / 2-hop）・検索
- `table:` ブロックの罫線描画（render-markdown.nvim 風、カーソル行はソース表示）
- PAT 認証（macOS Keychain 保存、または `COSENSE_PAT` 環境変数）。複数アカウント対応（`:Chatora account` で切り替え）
- 書き込みは公式 `page-edit-for-ai` API（preview → submit）。`:w` は同期なので `:wq` 一回で保存して閉じられる
- Cosense のエディタショートカット: `<C-t>` 日時挿入 / `<C-i>` 自分のアイコン挿入 / `[` の自動ペア

設計は [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) を参照。

## インストール

必要なもの: Neovim >= 0.11、node >= 20（LSP サーバーの実行）、bun（ビルド）。

lazy.nvim（GitHub から直接）:

```lua
{
  'qaynam/chatora',
  build = 'bun install && bun run build',
  cmd = 'Chatora',
  opts = {
    -- origin = 'https://scrapbox.io',  -- 既定値
    -- project = 'your-project',        -- 固定したい場合。未指定なら起動時に選択
    -- autosave = 3,                    -- 編集停止 n 秒後に自動保存（既定 false）
    -- pads = { bullet = '•', gap = 1 },-- 箇条書き表示のカスタマイズ / false で無効
    -- tables = false,                  -- table: ブロックの罫線描画を無効化（既定 true）
    -- related_auto_open = false,       -- 関連ページパネルの自動表示を止める（既定 true）
    -- external_link = 'open',          -- gd で確認なしにブラウザを開く（既定 'confirm'）
    -- status = false,                  -- 保存状態アイコン（✓/●/◍/✗）を無効化（既定 true）
    -- keymaps = false,                 -- <C-t>/<C-i>/[ 自動ペアを無効化（既定 true）
    -- image_border = false,            -- 画像上下の罫線を消す（既定 true）
    -- spacing = { line = 1, code = 0 },-- 行間（仮想空行）。既定はどちらも 0
  },
}
```

ローカル開発中のリポジトリを使う場合は `'qaynam/chatora'` の代わりに
`dir = '/path/to/chatora'` を指定（`build` は同じ）。

### 画像のインライン表示（任意）

アイコン記法や Gyazo 画像をバッファ内に描画するには、対応ターミナル
（kitty / Ghostty）+ ImageMagick（`brew install imagemagick`）+ 描画プラグインが必要:

```lua
-- 推奨: image.nvim（magick_cli プロセッサなら luarocks 不要）
{ "3rd/image.nvim", opts = { processor = "magick_cli" } },
-- 代替: snacks.nvim の image モジュールでも可（両方あれば image.nvim 優先）
```

画像の取得は chatora の LSP サーバーが PAT 付きで行いローカルにキャッシュするため、
プライベートプロジェクトのアイコンも表示できる。

### シェルから一発起動（任意）

`bin/chatora` が `nvim +Chatora` のランチャー。PATH に追加するかエイリアスで:

```sh
alias chatora='/path/to/chatora/bin/chatora'
```

以後、ターミナルで `chatora` と打つだけでサイドバー付きの nvim が立ち上がる。

## 使い方

1. `:Chatora` — 初回は PAT の入力を求められる（発行: https://scrapbox.io/settings/personal-access-tokens ）。検証後 macOS Keychain に保存される。`COSENSE_PAT` 環境変数があればそちらが優先される。
2. 左サイドバー: `<CR>` 開く / `R` 再読込 / `s` 検索 / `n` 新規ページ / `P` プロジェクト切替 / `q` 閉じる。
   上部に neo-tree 風のタブ（`<Tab>` / `<S-Tab>` / `1`..`9` / クリックで切替）があり、既定は「すべて」と
   「未読」（自分の Cosense 保存フィルタで絞った未読ページ）。`sidebar_tabs` で自由に定義できる。
   行頭は保存状態（`✓`/`●`）と未読バー（`▍`= 最後に見たあとに更新された。Cosense のグリッドの青ボーダーと同じ判定）
3. ページバッファ: 普通に編集して `:w` で保存（preview → submit の公式 API、同期なので `:wq` 一回で閉じられる）。`gR` で関連ページパネル（1-hop / 2-hop）をトグル（既定で自動表示、`q` で閉じると次の `gR` まで出ない）。`[` や `#` でリンク補完、`gd` でリンク先へジャンプ（外部 URL は確認のうえブラウザで開く）。
4. `:Chatora new [title]` — 新規ページ作成（title 省略時は入力プロンプト）
5. `:Chatora search [query]` / `:Chatora related` / `:Chatora project` / `:Chatora logout`
6. `:Chatora account` — アカウントの切り替え・追加（PAT ごとに 1 アカウント。切り替えるとサイドバーを再読込）
7. `:Chatora help` — コマンド・キーマップのチートシート

### 保存状態の表示

保存の成否はトーストではなく小さなアイコンで伝える: サイドバーの ● マーク、
コマンドラインへの一行 echo、そして statusline コンポーネント。
statusline に出すには（例: 素の statusline）:

```lua
vim.o.statusline = "%f %{%v:lua.require'chatora.status'.component()%}"
```

lualine など「色は自前で付ける」系のプラグインにはアイコンだけ返す
`require('chatora.status').icon(bufnr)`（戻り値: アイコン, ハイライト名）が使える。
アイコンは `✓` 保存済み / `●` 未保存 / `◍` 保存中 / `✗` 失敗（`status.icons` で変更可）。

## 開発

```sh
bun test                 # core + server の単体テスト
bun tests/e2e/run.ts     # 偽 Cosense サーバー + headless nvim の E2E
nvim --headless --clean -u NORC -c "luafile tests/smoke.lua"
```
