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
  opts = { project = 'your-project' },  -- 全オプションは下表
}
```

### 設定オプション

`setup()` / lazy.nvim の `opts` に渡す。既定値は `lua/chatora/config.lua`。

| オプション | 既定 | 意味 |
|---|---|---|
| `origin` | `https://scrapbox.io` | Cosense の origin |
| `project` | なし | 固定するプロジェクト。未指定なら起動時に選択 |
| `server_cmd` | 自動検出 | LSP サーバーの起動コマンド |
| `sidebar_width` | `32` | サイドバーの幅 |
| `sidebar_tabs` | すべて / 未読 | サイドバー上部のタブ。各要素は `{ label, filter?, unread_only? }`。`filter` は `'me'`（自分の保存済み Cosense フィルタ、無ければ自分の名前の icon フィルタ）か `{ type = 'icon', value = 'name' }`。`false` でタブなしの単一リスト |
| `sidebar_separator` | `true` | 行ごとの区切り下線。未読バーが一本線に見えるのを防ぐ |
| `sidebar_poll` | `60` | サイドバーを n 秒ごとに自動更新（更新順で先頭が入れ替わったときだけ再描画）。`false` で無効、最短 5 秒 |
| `related_height` | `8` | 関連ページパネルの高さ |
| `related_auto_open` | `true` | ページを開いたら関連パネルも開く。`q` で閉じると次の `gR` まで抑制 |
| `status` | `true` | 保存状態アイコン。`{ icons = { clean='✓', dirty='●', error='✗' }, echo = false }` で調整、`false` で無効 |
| `autosave` | `false` | 編集停止から n 秒後に自動保存 |
| `completion` | `'auto'` | `'auto'` は blink.cmp が無い/無効なときだけ Neovim 内蔵補完を有効化。`'native'` は常に有効、`false` は外部エンジンに任せる |
| `external_link` | `'confirm'` | 外部 URL 上の `gd`。`'open'` は確認なし、`'ignore'` は何もしない |
| `keymaps` | `true` | insert モードの Cosense ショートカット。`{ insert_date = '<C-t>', insert_icon = '<C-i>', date_format = '%Y-%m-%d %H:%M:%S', autopair = true, table_tab = true, toggle_sidebar = '<leader>ct' }`。**`<C-i>` は kitty keyboard protocol 対応端末（kitty / Ghostty / WezTerm）以外では `<Tab>` と同一**。そのため `<Tab>` は文脈で分岐する: 行頭の空白内ならインデント、テーブル行ならセル区切りのタブ、それ以外はアイコン挿入。`toggle_sidebar` は chatora が唯一設定するグローバルキーマップ |
| `images` | `'auto'` | 描画バックエンドが使えるときだけ画像を描く。`false` で無効 |
| `image_backend` | `'auto'` | `'auto'` は image.nvim 優先で snacks.nvim にフォールバック。`'image_nvim'` / `'snacks'` で固定 |
| `image_height` | `20` | 単独行の画像の高さ（行数）。文中のインライン画像は常に 1 行 |
| `image_border` | `true` | 画像自体に合成する枠（ImageMagick）。`{ width = 1, color = '#8888', padding = 12 }`（px、color は ImageMagick の色リテラル） |
| `pads` | `true` | 箇条書きの中点とガイド線。`{ bullet = '●', guide = '┃', spacing = true, gap = 1 }`。`gap` は中点と本文の間の余白セル数 |
| `conceal` | `true` | 記法マークアップをカーソル行以外で隠す（render-markdown.nvim 方式） |
| `tables` | `true` | `table:` ブロックの罫線描画。`{ border = false, header = false }` で個別に無効化 |
| `title_margin` | `1` | タイトル行の下に入れる仮想空行の数 |
| `spacing` | `{ line = 0, code = 0 }` | 行間として挿入する仮想空行。ターミナルはセル高が固定なので、本当の行高は端末/GUI 側の設定（`linespace` 等） |
| `notations` | `{}` | ユーザー定義のカスタム装飾記法 `[<記号> 本文]`。下記参照 |

### カスタム装飾記法（`notations`）

`[<記号> 本文]` の記号を自分で定義して好きなハイライトを当てられる:

```lua
notations = {
  ['|'] = { name = 'highlight', hl = { bg = '#3a3a00', bold = true } },
  ['='] = { name = 'boxed',     hl = { link = 'WarningMsg' } },
  ['@'] = { name = 'heading', icon = '📌', hl = { bold = true, underline = true } },
}
```

- キー = `[` の直後に来る 1 文字の記号。公式記法の記号（`* / - _ $ [ #`）とは衝突不可
- `name` = 英数字と `_` のみ（semantic token 型名になる）
- `hl` = `nvim_set_hl` にそのまま渡る（`:colorscheme` 変更後も再適用される）
- `icon`（任意）= 開きマーカー（`[<記号> ` の部分）をこの 1 文字に置き換えて表示する。カーソル行では
  `concealcursor` により自動的に元の記号が見える。Neovim の conceal 置換は 1 文字までしか使えないため、
  複数文字を指定した場合は警告して無視される（`name`/`hl` は活きたまま）

不正な設定（記号が1文字でない・`name` が不正・公式記法と衝突）はエントリごと `vim.notify` で警告して無視される。
`icon` だけが1文字でない場合はエントリは活かしたまま `icon` だけを警告して無視する。

`gap = 0` にすると中点が本文に密着するが、中点は overlay で描くため、端末が
East Asian Ambiguous 幅の文字を 2 セルで描く設定だと次の 1 文字を潰す。
その場合は `ambiwidth` を端末に合わせるか `gap` を 1 以上にする。

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
2. 左サイドバー: `<CR>` または `l` 開く / `R` 再読込 / `s` 検索 / `n` 新規ページ / `P` プロジェクト切替 / `q` 閉じる。
   上部に neo-tree 風のタブ（`<Tab>` / `<S-Tab>` / `1`..`9` / クリックで切替）があり、既定は「すべて」と
   「未読」（自分の Cosense 保存フィルタで絞った未読ページ）。`sidebar_tabs` で自由に定義できる。
   行頭は保存状態（`✓`/`●`）と未読バー（`▍`= 最後に見たあとに更新された。Cosense のグリッドの青ボーダーと同じ判定）
3. ページバッファ: 普通に編集して `:w` で保存（preview → submit の公式 API、同期なので `:wq` 一回で閉じられる）。`gR` で関連ページパネル（1-hop / 2-hop）をトグル（既定で自動表示、`q` で閉じると次の `gR` まで出ない）。`[` や `#` でリンク補完、`gd` でリンク先へジャンプ（外部 URL は確認のうえブラウザで開く）。
4. `:Chatora new [title]` — 新規ページ作成（title 省略時は入力プロンプト）
5. `:Chatora toggle` — サイドバーの開閉
6. `:Chatora search [query]` / `:Chatora related` / `:Chatora project` / `:Chatora logout`
7. `:Chatora account` — アカウントの切り替え・追加（PAT ごとに 1 アカウント。切り替えるとサイドバーを再読込）
8. `:Chatora help` — コマンド・キーマップのチートシート

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
