# chatora 🐈

Cosense（旧 Scrapbox）の Neovim クライアント。

- 左サイドバーにページ一覧、右に本物の Neovim エディタ
- `@cosense-toolbox/parser` による記法ハイライト（LSP semantic tokens）
- リンク補完・定義ジャンプ・関連ページ（1-hop / 2-hop）・検索
- `table:` ブロックの罫線描画（render-markdown.nvim 風、カーソル行はソース表示）
- PAT 認証（macOS Keychain 保存、または `COSENSE_PAT` 環境変数）。複数アカウント対応（`:Chatora account` で切り替え）
- 書き込みは公式 `page-edit-for-ai` API（preview → submit）。`:w` は同期なので `:wq` 一回で保存して閉じられる
- Cosense のエディタショートカット: `<C-t>` 日時挿入 / `<C-i>` アイコン挿入 / `[` の自動ペア / visual モードで `*` `_` `-` `/` `[` を押すと選択を囲む

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
| `related_height` | `8` | 関連ページパネルの高さ。各行に被リンク数、見出しに件数、winbar にそのページ自身の被リンク数が出る |
| `related_auto_open` | `true` | ページを開いたら関連パネルも開く。`q` で閉じると次の `gR` まで抑制 |
| `status` | `true` | 保存状態アイコン。`{ icons = { clean='✓', dirty='●', error='✗' }, echo = false }` で調整、`false` で無効 |
| `autosave` | `false` | 編集停止から n 秒後に自動保存 |
| `completion` | `'auto'` | `'auto'` は blink.cmp が無い/無効なときだけ Neovim 内蔵補完を有効化。`'native'` は常に有効、`false` は外部エンジンに任せる |
| `external_link` | `'confirm'` | 外部 URL 上の `gd`。`'open'` は確認なし、`'ignore'` は何もしない |
| `log` | `false` | 診断ログ。`true` で `${XDG_STATE_HOME:-~/.local/state}/chatora/chatora.log`、文字列ならそのパス。`:Chatora log` で開く |
| `keymaps` | `true` | insert モードの Cosense ショートカットと `<leader>c` 名前空間。`{ insert_date = '<C-t>', insert_icon = { '<C-i>', '<M-i>' }, date_format = '%Y-%m-%d %H:%M:%S', autopair = true, table_tab = true, prefix = '<leader>c' }`。個別のグローバルキーは `{ toggle = '<leader>b', info = false }` のようにアクション名で上書き・無効化できる（下表）。**`<C-i>` は kitty keyboard protocol 対応端末以外では `<Tab>` と同一**（下記参照）|
| `images` | `'auto'` | 描画バックエンドが使えるときだけ画像を描く。`false` で無効 |
| `image_backend` | `'auto'` | `'auto'` は image.nvim 優先で snacks.nvim にフォールバック。`'image_nvim'` / `'snacks'` で固定 |
| `image_height` | `20` | 単独行の画像の高さ（行数）。文中のインライン画像は常に 1 行 |
| `image_height_large` | `image_height * 2` | `[[url]]`（Cosense の大きい画像記法）の高さ |
| `image_gallery` | `true` | 画像だけの行を大きく描く。行のインデントに揃えて**縦に積む**（横並びは 1 行の高さでしか描けない。下記参照）。数値でその高さ、`false` で従来の行内 1 行 |
| `image_border` | `true` | 画像自体に合成する枠（ImageMagick）。`{ width = 1, color = '#8888', padding = 12 }`（px、color は ImageMagick の色リテラル） |
| `pads` | `true` | 箇条書きの中点。`{ bullet = '●', guide = false, spacing = true, gap = 0 }`。`guide` に文字を渡すと上位レベルに縦線を引く（Cosense には無い）。`gap` は中点と本文の間の余白セル数で、既定の 0 でも本文との間にはインデント1文字分が残る |
| `quote` | `true` | `>` 行を GitHub 風の縦棒付きで描く。下記参照 |
| `conceal` | `true` | 記法マークアップをカーソル行以外で隠す（render-markdown.nvim 方式） |
| `tables` | `true` | `table:` ブロックの罫線描画。`{ border = false, header = false }` で個別に無効化 |
| `title_margin` | `1` | タイトル行の下に入れる仮想空行の数 |
| `spacing` | `{ line = 0, code = 0 }` | 行間として挿入する仮想空行。ターミナルはセル高が固定なので、本当の行高は端末/GUI 側の設定（`linespace` 等） |
| `notations` | `{}` | ユーザー定義のカスタム装飾記法 `[<記号> 本文]`。下記参照 |

#### `<C-i>` が効かないとき

Cosense のアイコン挿入は `<C-i>` だが、端末は kitty keyboard protocol を話すときだけこれを
`<Tab>` と別のキーとして送る。それ以外では**同じバイト**で届き、`<Tab>` は補完プラグイン
（blink.cmp / nvim-cmp）のものなので、アイコンではなく補完メニューが出る。

- **kitty / Ghostty / WezTerm** はそのまま対応。**tmux 越しなら `set -g extended-keys on` が必要**
- 対応させたくない場合は既定でもう一つ入っている **`<M-i>`（Alt+i）** を使う。どのプラグインとも
  競合しない
- Ghostty なら Cmd も渡せる。設定に `keybind = cmd+i=text:\x1bi` を入れると Cmd+I が `<M-i>` として
  届く

chatora は `<Tab>` を奪わない。**テーブル行のときだけ**本物のタブ（`expandtab` だとセル区切りに
ならないため）を入れ、それ以外は元々そのキーを持っていたマッピングにそのまま委譲する。

#### アイコン挿入は文脈で変わる

アイコンキーは押した場所で意味が変わる（Cosense web と同じ）:

| 状況 | 挿入されるもの |
|---|---|
| リンク補完が開いていて候補が選択されている | **その候補の**アイコン `[候補.icon]`（書きかけの `[...]` ごと置換） |
| それ以外 | 自分のアイコン `[自分.icon]` |

blink.cmp / nvim-cmp / 組み込み補完のどれでも動く（選択中の候補をエンジンごとに問い合わせる）。
ターミナルなので**補完メニューの中にアイコン画像は出せない** — 出せるのは挿入だけ。

### visual モードの装飾記法（`surround`）

選択して記号を押すと Cosense と同じように囲む。同じキーをもう一度押すと入れ子にせず中身を書き換える。

| 押す | 結果 |
|---|---|
| `*` | `[* 選択]` |
| `*` `*` `*` | `[*** 選択]`（`[*****]` で頭打ち） |
| `_` / `-` / `/` | `[_ 選択]` / `[- 選択]` / `[/ 選択]`（もう一度押すと外れる） |
| `[` | `[選択]`。リンクは育てるものではないので **normal モードに戻る** |
| ユーザー定義記法の記号 | `[<記号> 選択]` |

`surround = false` で全部やめる。記号のリストを渡すとその記号だけになる。

### グローバルキーマップ（`<leader>c`）

`keymaps.prefix`（既定 `<leader>c`）の下に並ぶ。`prefix = false` で全部やめる。

| キー | 動作 | アクション名 |
|---|---|---|
| `<leader>ct` | サイドバーを開閉 | `toggle` |
| `<leader>cs` | ページを検索 | `search` |
| `<leader>cn` | 新規ページ | `new` |
| `<leader>cr` | 関連ページを開閉 | `related` |
| `<leader>ci` | ページ情報（更新日時・閲覧数・被リンク・ピン留め・URL） | `info` |
| `<leader>cf` | サーバーの変更を取り込む（`git pull` 相当。未保存の変更はマージされる） | `pull` |
| `<leader>cc` | 次の競合行へ移動（ページバッファでは `]c` も） | `next_conflict` |
| `<leader>cv` | クリップボードの画像をアップロードして記法を挿入 | `paste_image` |
| `<leader>cy` | ページ URL をコピー | `copy_url` |
| `<leader>cY` | リンク記法 `[タイトル]` をコピー | `copy_link` |
| `<leader>co` | ブラウザで開く | `open_in_browser` |
| `<leader>ca` | アカウント切り替え | `account` |
| `<leader>cp` | プロジェクト切り替え | `project` |
| `<leader>c?` | ヘルプ | `help` |

個別に変えるならアクション名をキーにする: `keymaps = { info = '<leader>ck', copy_url = false }`。

#### 画像だけの行（`image_gallery`）

`[img1] [img2] [img3]` のように画像しか無い行は、web だと横に流れて折り返す。ターミナルでは
描画バックエンド（snacks.nvim / image.nvim）が画像を **1 行分のインライン仮想テキスト**か
**行の下の仮想行**のどちらかでしか描けないため、次の二択になる:

| | 横並び | 大きさ |
|---|---|---|
| `image_gallery = false` | ✅ 折り返しも自然 | ❌ 1 行 |
| `image_gallery = true`（既定） | ❌ 縦に積む | ✅ |

既定は後者。積むときは各画像を**行のインデントに揃える**ので、階段状にならず一列になる。

### 引用（`quote`）

`> 引用` の `>` を縦棒で置き換え、本文を淡く落とす:

```lua
quote = {
  bar = '▌',                              -- 太さはグリフで決まる: ▏ ▎ ▍ ▌ ┃ │
  hl = { fg = '#4493f8' },                -- 縦棒の色（ChatoraQuoteBar）
  text_hl = { fg = '#9198a1', italic = true }, -- 引用本文（ChatoraQuoteText）
  dim = false,                            -- 本文はそのままにして縦棒だけ出す
  wrap = false,                           -- 折り返し行への縦棒の追従をやめる
}
```

`hl` / `text_hl` は `nvim_set_hl` にそのまま渡る。省略するとどちらも `Comment` にリンクする。
縦棒は conceal ではなく overlay なので、カーソルがその行に来ても消えない。

`wrap = true`（既定）のとき、折り返された引用の 2 行目以降にも縦棒が続くよう
`breakindent` と `breakindentopt=shift:2` をページのウィンドウに設定する。この字下げが無いと
縦棒が折り返し行の 1 文字目を潰すため、`wrap = false` にすると追従自体をやめる。

### カスタム装飾記法（`notations`）

`[<記号> 本文]` の記号を自分で定義して好きなハイライトを当てられる:

```lua
notations = {
  ['|'] = { name = 'highlight', hl = { bg = '#3a3a00', bold = true } },
  ['='] = { name = 'boxed',     hl = { link = 'WarningMsg' } },
  ['@'] = { name = 'heading', icon = '📌', hl = { bold = true }, rule = true },
}
```

- キー = 1 文字の記号。公式記法の記号（`* / - _ $ [`）とは衝突不可
- `name` = 英数字と `_` のみ（semantic token 型名になる）
- `hl` = `nvim_set_hl` にそのまま渡る（`:colorscheme` 変更後も再適用される）
- `icon`（任意）= 開きマーカー（`[<記号> ` の部分）をこの 1 文字に置き換えて表示する。カーソル行では
  `concealcursor` により自動的に元の記号が見える。Neovim の conceal 置換は 1 文字までしか使えないため、
  複数文字を指定した場合は警告して無視される（`name`/`hl` は活きたまま）
- `rule`（任意）= `true` にすると、その行の下に**ウィンドウの右端まで届く**罫線を引く（見出し用）。
  文字幅の下線が欲しいだけなら `hl = { underline = true }` で足りる。色は `rule_hl`（省略時は
  `WinSeparator` の色）

Cosense のマーカーは 1 文字ではなく記号の連なりなので、公式記法と混ぜて書ける。
`[|* 特徴]` は `|`（上の例なら `highlight`）と `*`（太字）の両方を持つ。
ハイライトは 1 スパンに 1 つしか当たらないため、混在時はカスタム記法の `hl` が勝つ。

不正な設定（記号が1文字でない・`name` が不正・公式記法と衝突）はエントリごと `vim.notify` で警告して無視される。
`icon` だけが1文字でない場合はエントリは活かしたまま `icon` だけを警告して無視する。

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

### 画像の貼り付け（`<leader>cv`）

クリップボードの画像をそのまま Cosense に上げて、カーソルの下の行に画像記法を書き込む。
アップロード中はその行にスピナーが出る。

Neovim のレジスタはテキストしか持てないので、画像のバイト列を取り出すのに外部ツールが要る
（最初に見つかったものを使う）:

| プラットフォーム | ツール |
|---|---|
| macOS | `pngpaste`（`brew install pngpaste`）。無ければ標準の `osascript` にフォールバック |
| Wayland | `wl-paste` |
| X11 | `xclip` |

アップロード先を決めるのは chatora ではなくプロジェクト側の設定
（`/api/projects/<name>` の `uploadImageTo`）で、Cosense web と同じ判定をアップロードごとに
やり直す。プロジェクトを切り替えれば行き先も切り替わる:

| `uploadImageTo` | 行き先 | 挿入される記法 |
|---|---|---|
| `gyazo` | Gyazo（`oauth-upload/token` → `upload.gyazo.com/api/upload`） | `[https://gyazo.com/…]` |
| `gcs` | プロジェクト自身のファイル領域（`/api/gcs/<id>/upload-request` → 署名付き URL に PUT → `/verify`） | `[https://scrapbox.io/files/….png]` |

プロジェクト設定が読めなかったときは Gyazo に倒す（ファイル領域を持たないプロジェクトでも
通る方だから）。

### telescope 連携（任意）

同じ全文検索を telescope のピッカーとしても使える:

```lua
require('telescope').load_extension('chatora')
```

`:Telescope chatora search`（`:Telescope chatora` も同じ）。並び順は Cosense の pageRank を
そのまま使い、telescope 側では一致箇所のハイライトだけを行う。プレビューはページ本文で、
ヒット行に飛んで `TelescopePreviewMatch` でマークする。`dynamic_preview_title = true` を
設定していればプレビューの枠にページ名が出る。

`:Chatora search` は telescope を入れていなくても動く chatora 内蔵のピッカーで、こちらとは別物。

### シェルから一発起動（任意）

`bin/chatora` が `nvim +Chatora` のランチャー。PATH に追加するかエイリアスで:

```sh
alias chatora='/path/to/chatora/bin/chatora'
```

以後、ターミナルで `chatora` と打つだけでサイドバー付きの nvim が立ち上がる。

## 使い方

0. `:Chatora <url>` — Cosense のページ URL をそのまま渡すとそのページを開く（`chatora <url>` も同じ）
1. `:Chatora` — 初回は PAT の入力を求められる（発行: https://scrapbox.io/settings/personal-access-tokens ）。検証後 macOS Keychain に保存される。`COSENSE_PAT` 環境変数があればそちらが優先される。
2. 左サイドバー: `<CR>` または `l` 開く / `R` 再読込 / `s` 検索 / `n` 新規ページ / `P` プロジェクト切替 / `q` 閉じる。
   上部に neo-tree 風のタブ（`<Tab>` / `<S-Tab>` / `1`..`9` / クリックで切替）があり、既定は「すべて」と
   「未読」（自分の Cosense 保存フィルタで絞った未読ページ）。`sidebar_tabs` で自由に定義できる。
   行頭は保存状態（`✓`/`●`）と未読バー（`▍`= 最後に見たあとに更新された。Cosense のグリッドの青ボーダーと同じ判定）
3. ページバッファ: 普通に編集して `:w` で保存（preview → submit の公式 API、同期なので `:wq` 一回で閉じられる）。`gR` で関連ページパネル（1-hop / 2-hop）をトグル（既定で自動表示、`q` で閉じると次の `gR` まで出ない）。`[` や `#` でリンク補完、`gd` でリンク先へジャンプ（外部 URL は確認のうえブラウザで開く）。
4. `:Chatora new [title]` — 新規ページ作成（title 省略時は入力プロンプト）
5. `:Chatora toggle` — サイドバーの開閉
6. `:Chatora log` — 診断ログを開く（`log` オプションが必要）
7. `:Chatora search [query]` — 全文検索。プロンプトの下に結果、右にそのページの本文（ヒット行に飛んでハイライト）。`<C-d>`/`<C-u>` でプレビューをスクロール
   `:Chatora related` / `:Chatora project` / `:Chatora logout`
7. `:Chatora account` — アカウントの切り替え・追加（PAT ごとに 1 アカウント。切り替えるとサイドバーを再読込）
8. `:Chatora help` — コマンド・キーマップのチートシート

### 同期と競合（`sync`）

開いているページはバックグラウンドでサーバーと同期される。**取り込みは上書きではなくマージで、
ローカルで書いた内容が消えることはない。**

```lua
sync = { interval = 30, on_focus = true, notify = true }  -- 既定
sync = false                                              -- 手動（<leader>cf）だけにする
```

- `interval` — ポーリング間隔（秒）。**画面に出ているバッファだけ**を回し、離れると止まり、戻ると再開する
- `on_focus` — ページに入った瞬間にも一度同期する
- `notify` — 取り込んだ内容・競合件数を通知する

マージは三方向（`base` = 最後に取得した状態 / `ours` = バッファ / `theirs` = サーバーの現在）で、
突き合わせは行テキストではなく**行 ID** で行う。ローカルは行 ID に紐づけ直され、リモートは
最初から ID を持っているので、リモート側の並べ替え・挿入・削除に引きずられない。

| 状況 | 結果 |
|---|---|
| 別々の行を編集 | 両方入る |
| 同じ行を同じ内容に編集 | 競合しない |
| 同じ行を違う内容に編集 | **ローカルを残す** + 競合として印を付ける |
| ローカルで編集した行をサーバーが削除 | **ローカルの行を残す** + 競合 |
| ローカルで削除した行をサーバーが編集 | サーバーの行が戻る + 競合（削除はやり直せるが、消えた文章は戻せないため） |

競合した行は行ハイライトと行末の `◆ サーバー: …` で示される。**バッファに `<<<<<<<` のような
マーカーは一切書き込まない** — バッファは常に保存される内容とバイト単位で一致している必要があるため。
`]c` で次の競合へ飛べる。

保存時に競合が出た場合は書き込みを行わず、マージ結果を表示したうえでバッファを未保存のままにする。
直してからもう一度 `:w` すればよい。

> Cosense の書き込み API はクライアント側のバージョン token を受け取らない
> （`page-edit-for-ai/preview` の body は `{pageId, changes}` のみ）。サーバーは preview 時点の状態と
> 突き合わせて `409 NotFastForward` を返すので、chatora はそれを受けて取り直し → 三方向マージ →
> 再送する。衝突が本当に同じ行で起きたときだけ保存が止まる。

### 保存状態の表示

保存の成否はトーストではなく小さなアイコンで伝える: サイドバーの ● マーク、
コマンドラインへの一行 echo、そして statusline コンポーネント。
statusline に出すには（例: 素の statusline）:

```lua
vim.o.statusline = "%f %{%v:lua.require'chatora.status'.component()%}"
```

`component()` はアイコンだけを返す（サイドバーの winbar でもこれを使っている）。ページの
数値は `page_info()`:

```lua
-- 素の statusline
vim.o.statusline = "%f %{%v:lua.require'chatora.status'.component()%} %{v:lua.require'chatora.status'.page_info()}"

-- lualine
{ sections = { lualine_x = {
  { function() return require('chatora.status').page_info() end,
    color = function() return require('chatora.status').page_info_hl() end },
} } }
```

`更新 43分前 · 閲覧 39 · 被リンク 6` のような**プレーン文字列**を返し、ページ以外のバッファでは
空文字（条件を書かずにそのまま置ける）。色は `page_info_hl()` がハイライトグループ名で返す。

**Cosense の日時はサーバー側のコピーの話**なので、ローカルに未保存の変更があると黙って嘘に
なる。そのためバッファが未保存のときは先頭にバッジが付き、`page_info_hl()` も警告色を返す:

| 状態 | `page_info()` | `page_info_hl()` |
|---|---|---|
| 保存済み | `更新 43分前 · 閲覧 39` | `ChatoraStatusMuted` |
| 未保存 | `● 未保存 · 更新 43分前 · 閲覧 39` | `ChatoraStatusDirty` |
| 保存中 | `◍ 保存中 · …` | `ChatoraStatusPending` |
| 保存失敗 | `✗ 保存失敗 · …` | `ChatoraStatusError` |

更新時刻だけなら `require('chatora.status').updated(bufnr)`。全項目（作成日・ページ履歴・
ページランク・ピン留め）は `<leader>ci` のページ情報パネルに出る。

lualine など「色は自前で付ける」系のプラグインにはアイコンだけ返す
`require('chatora.status').icon(bufnr)`（戻り値: アイコン, ハイライト名）が使える。
アイコンは `✓` 保存済み / `●` 未保存 / `◍` 保存中 / `✗` 失敗（`status.icons` で変更可）。

## 開発

nvim を再起動せずにプラグインを入れ替えるには `:Chatora reload`。LSP を止め、chatora の
ウィンドウとバッファを畳み、`package.loaded` から chatora のモジュールを落として同じ
オプションで `setup()` をやり直す。**サーバー側を変えたときは先に `bun run build`**（クライアントは
プロセスを起動し直すだけでビルドはしない）。

```sh
bun test                 # core + server の単体テスト
bun tests/e2e/run.ts     # 偽 Cosense サーバー + headless nvim の E2E
nvim --headless --clean -u NORC -c "luafile tests/smoke.lua"
```
