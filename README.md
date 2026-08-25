# chatora 🐈

Cosense（旧 Scrapbox）を Neovim から読み書きするためのクライアント。

左にページ一覧、右に本物の Neovim バッファ。記法のハイライトとリンク補完は
[@cosense-toolbox/parser](https://www.npmjs.com/package/@cosense-toolbox/parser) を積んだ
LSP サーバーが担当し、Neovim 側は薄い UI 層に徹する。

```
┌─ sidebar ──┬─ cosense://project/page ─────────────┐
│ ページ一覧 │ • 本文を普通に編集して :w で保存      │
│ すべて/未読│ • 記法は semantic tokens でハイライト │
│            ├─ 関連ページ（1-hop / 2-hop）─────────┤
└────────────┴──────────────────────────────────────┘
```

## 特長

- **編集はローカル、同期はマージ** — 開いているページは背後でサーバーと同期する。取り込みは
  上書きではなく行 ID ベースの三方向マージなので、書きかけの内容が消えない
- **記法のハイライト** — 装飾・リンク・コードブロック・テーブル・引用・画像を LSP semantic
  tokens で描く。マークアップはカーソル行以外で隠す
- **リンク補完と定義ジャンプ** — `[` や `#` で候補、`gd` でページへ。実体のないページ（赤リンク）は
  色で分かる
- **画像のインライン表示と貼り付け** — 対応ターミナルなら本文中に描画。クリップボードの画像は
  `<leader>cv` でそのままアップロード
- **Cosense のエディタ操作** — `<C-t>` 日時挿入、`<C-i>` アイコン挿入、`[` の自動ペア、visual
  モードで `*` や `[` を押して選択を囲む
- **PAT 認証・複数アカウント** — macOS Keychain に保存。`:Chatora account` で切り替え

設計と内部プロトコルは [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 必要なもの

| | |
|---|---|
| Neovim | >= 0.11 |
| Node.js | >= 20（LSP サーバーの実行） |
| bun | ビルド時のみ |

任意: ImageMagick と画像描画プラグイン（[画像の表示](#画像の表示)）、クリップボード取り出しツール
（[画像の貼り付け](#画像の貼り付け)）。

## インストール

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'qaynam/chatora',
  build = 'bun install && bun run build',
  cmd = 'Chatora',
  opts = {
    project = 'your-project',  -- 省略すると起動時に選択
  },
}
```

ローカルのリポジトリを使うなら `'qaynam/chatora'` の代わりに `dir = '/path/to/chatora'`
（`build` は同じ）。

## はじめかた

1. `:Chatora` を実行する。初回は PAT の入力を求められる
   （発行: `<origin>/settings/personal-access-tokens`）。検証後に macOS Keychain へ保存する。
   `COSENSE_PAT` 環境変数があればそちらが優先される
2. サイドバーからページを選ぶと `cosense://<project>/<title>` バッファが開く
3. 普通に編集して `:w`。`:wq` 一回で保存して閉じられる

## コマンド

| コマンド | 動作 |
|---|---|
| `:Chatora` | サイドバーを開く（初回は認証 → プロジェクト選択） |
| `:Chatora <url>` | Cosense のページ URL をそのまま開く |
| `:Chatora toggle` | サイドバーを開閉 |
| `:Chatora new [title]` | 新規ページ（title 省略時は入力プロンプト） |
| `:Chatora search [query]` | 全文検索（内蔵ピッカー） |
| `:Chatora related` | 関連ページパネルを開閉 |
| `:Chatora account` | アカウントの切り替え・追加 |
| `:Chatora project` | プロジェクトの切り替え |
| `:Chatora logout` | 現在のアカウントを削除 |
| `:Chatora log` | 診断ログを開く（`log` オプションが必要） |
| `:Chatora reload` | プラグインを再読み込み（開発用） |
| `:Chatora help` | チートシート |

## キーマップ

### グローバル（`<leader>c`）

`keymaps.prefix`（既定 `<leader>c`）の下に並ぶ。`prefix = false` で全部やめる。

| キー | 動作 | アクション名 |
|---|---|---|
| `<leader>ct` | サイドバーを開閉 | `toggle` |
| `<leader>cs` | ページを検索 | `search` |
| `<leader>cn` | 新規ページ | `new` |
| `<leader>cr` | 関連ページを開閉 | `related` |
| `<leader>cR` | 関連ページを下／右に切り替え | `related_side` |
| `<leader>ci` | ページ情報 | `info` |
| `<leader>cf` | サーバーの変更を取り込む | `pull` |
| `<leader>cc` | 次の競合行へ | `next_conflict` |
| `<leader>cv` | クリップボードの画像を貼り付け | `paste_image` |
| `<leader>cd` | ページを削除（確認あり） | `delete` |
| `<leader>cy` | ページ URL をコピー | `copy_url` |
| `<leader>cY` | リンク記法 `[タイトル]` をコピー | `copy_link` |
| `<leader>co` | ブラウザで開く | `open_in_browser` |
| `<leader>ca` | アカウント切り替え | `account` |
| `<leader>cp` | プロジェクト切り替え | `project` |
| `<leader>c?` | ヘルプ | `help` |

個別に変えるならアクション名をキーにする:

```lua
keymaps = { info = '<leader>ck', copy_url = false }
```

### ページバッファ

| キー | 動作 |
|---|---|
| `gd` | リンク先へジャンプ（外部 URL はブラウザ） |
| `gR` | 関連ページパネルを開閉 |
| `gs` | ページを検索 |
| `]c` | 次の競合行へ |
| `:w` / `:wq` | 保存（同期） |

### サイドバー

| キー | 動作 |
|---|---|
| `<CR>` / `l` | 開く |
| `<Tab>` / `<S-Tab>` / `1`..`9` | タブ切り替え（クリックも可） |
| `R` | 再読込 |
| `s` | 検索 |
| `n` | 新規ページ |
| `P` | プロジェクト切り替え |
| `q` | 閉じる |

行頭には保存状態（`✓` / `●`）と未読バー（`▍` = 最後に見たあとに更新された）が出る。

### insert モード

| キー | 動作 |
|---|---|
| `<C-t>` | 日時を挿入 |
| `<C-i>` / `<M-i>` | アイコンを挿入（[下記](#アイコン挿入)） |
| `[` | `[]` を自動ペア（リンク補完はこの閉じたペアの中でのみ発火） |
| `<Tab>` | テーブル行では本物のタブ、それ以外は元のマッピングに委譲 |

### visual モード

選択して記号を押すと囲む。同じキーをもう一度押すと入れ子にせず中身を書き換える。

| 押す | 結果 |
|---|---|
| `*` | `[* 選択]` |
| `*` `*` `*` | `[*** 選択]`（`[*****]` で頭打ち） |
| `_` / `-` / `/` | `[_ 選択]` など（もう一度押すと外れる） |
| `[` | `[選択]`。リンクは育てるものではないので normal モードに戻る |
| ユーザー定義記法の記号 | `[<記号> 選択]` |

`surround = false` で全部やめる。記号のリストを渡すとその記号だけになる。

## 設定

`setup()` / lazy.nvim の `opts` に渡す。既定値は `lua/chatora/config.lua`。

### 接続

| オプション | 既定 | 意味 |
|---|---|---|
| `origin` | `'https://scrapbox.io'` | Cosense の origin |
| `project` | なし | 固定するプロジェクト。未指定なら起動時に選択 |
| `server_cmd` | 自動検出 | LSP サーバーの起動コマンド |
| `log` | `false` | 診断ログ。`true` で `${XDG_STATE_HOME:-~/.local/state}/chatora/chatora.log`、文字列ならそのパス |

### サイドバー・関連ページ

| オプション | 既定 | 意味 |
|---|---|---|
| `sidebar_width` | `32` | 幅 |
| `sidebar_tabs` | すべて / 未読 | 上部のタブ。[下記](#サイドバーのタブ) |
| `sidebar_separator` | `true` | 行ごとの区切り下線 |
| `sidebar_poll` | `60` | n 秒ごとに自動更新。`false` で無効、最短 5 秒 |
| `related_position` | `'bottom'` | 関連ページパネルの位置。`'right'` で全高の縦カラム |
| `related_height` | `8` | `'bottom'` のときの高さ |
| `related_width` | `40` | `'right'` のときの幅 |
| `related_auto_open` | `true` | ページを開いたら関連パネルも開く。`q` で閉じると次の `gR` まで抑制 |

### 編集・保存

| オプション | 既定 | 意味 |
|---|---|---|
| `sync` | `{ interval = 30, on_focus = true, notify = true }` | 背後での同期。[下記](#同期と競合) |
| `autosave` | `false` | 編集停止から n 秒後に自動保存 |
| `status` | `true` | 保存状態アイコン。`{ icons = {...}, echo = false }` で調整 |
| `keymaps` | `true` | キーマップ全般。`{ insert_date, insert_icon, date_format, autopair, table_tab, prefix }` |
| `surround` | `true` | visual モードの装飾キー。記号のリストで限定、`false` で無効 |
| `completion` | `'auto'` | `'auto'` は外部エンジンが無いときだけ内蔵補完を有効化。`'native'` は常に、`false` は外部任せ |
| `external_link` | `'confirm'` | 外部 URL 上の `gd`。`'open'` は確認なし、`'ignore'` は何もしない |

### 表示

| オプション | 既定 | 意味 |
|---|---|---|
| `conceal` | `true` | 記法マークアップをカーソル行以外で隠す |
| `pads` | `true` | 箇条書きの中点。[下記](#箇条書き) |
| `quote` | `true` | `>` 行の縦棒。[下記](#引用) |
| `tables` | `true` | `table:` ブロックの罫線。`{ border = false, header = false }` |
| `codeblock_numbers` | `true` | コードブロックの行番号 |
| `title_margin` | `1` | タイトル行の下に入れる仮想空行の数 |
| `spacing` | `{ line = 0, code = 0 }` | 行間に挿入する仮想空行 |
| `notations` | `{}` | ユーザー定義の装飾記法。[下記](#カスタム装飾記法) |

### 画像

| オプション | 既定 | 意味 |
|---|---|---|
| `images` | `'auto'` | 描画バックエンドが使えるときだけ描く。`false` で無効 |
| `image_backend` | `'auto'` | `'auto'` は image.nvim 優先で snacks.nvim にフォールバック |
| `image_height` | `20` | 単独行の画像の高さ（行数）。文中のインライン画像は常に 1 行 |
| `image_height_large` | `image_height * 2` | `[[…]]`（大きい記法）の高さ。画像とアイコンの両方に効く |
| `image_gallery` | `true` | 画像だけの行を大きく描く。[下記](#画像だけの行) |
| `image_border` | `true` | 画像に合成する枠。`{ width = 1, color = '#8888', padding = 12 }` |

## 機能

### 同期と競合

開いているページは背後でサーバーと同期する。**取り込みは上書きではなくマージで、ローカルで
書いた内容が消えることはない。**

```lua
sync = { interval = 30, on_focus = true, notify = true }  -- 既定
sync = false                                              -- 手動（<leader>cf）だけにする
```

- `interval` — ポーリング間隔（秒）。**画面に出ているバッファだけ**を回し、離れると止まり、
  戻ると再開する
- `on_focus` — ページに入った瞬間にも一度同期する
- `notify` — 取り込んだ内容・競合件数を通知する

マージは三方向（`base` = 最後に取得した状態 / `ours` = バッファ / `theirs` = サーバーの現在）で、
突き合わせは行テキストではなく**行 ID** で行う。ローカル側の編集は行 ID に紐づけ直され、
リモート側は最初から ID を持っているので、リモートの並べ替え・挿入・削除に引きずられない。

| 状況 | 結果 |
|---|---|
| 別々の行を編集 | 両方入る |
| 同じ行を同じ内容に編集 | 競合しない |
| 同じ行を違う内容に編集 | **ローカルを残す** + 競合として印を付ける |
| ローカルで編集した行をサーバーが削除 | **ローカルの行を残す** + 競合 |
| ローカルで削除した行をサーバーが編集 | サーバーの行が戻る + 競合 |

最後の 1 つだけローカルの意思が通らない。削除はやり直せるが、消えた文章は戻せないため。

競合した行は行ハイライトと行末の `◆ サーバー: …` で示す。**バッファには `<<<<<<<` のような
マーカーを一切書き込まない** — バッファは常に保存される内容とバイト単位で一致している必要が
あるため。`]c` で次の競合へ飛べる。

保存時に競合が出た場合は書き込みを行わず、マージ結果を表示したうえでバッファを未保存のまま
残す。直してからもう一度 `:w` すればよい。

> 書き込みは公式の `page-edit-for-ai` API（preview → submit）。この API はクライアント側の
> バージョン token を受け取らず、サーバーが preview 時点の状態と突き合わせて
> `409 NotFastForward` を返す。chatora はそれを受けて取り直し → 三方向マージ → 再送するので、
> 本当に同じ行が衝突したときだけ保存が止まる。

### 別プロジェクトのページ

`[/other-project/page]` に `gd` すると、そのプロジェクトのページが開く。Cosense は公開
プロジェクトを誰でも読めて、書けるのはメンバーだけなので、**自分がメンバーでないプロジェクトの
ページは読み取り専用で開く**。バッファは `nomodifiable` になり、statusline には `読み取り専用`
と出る。同期のポーリングも回さない。

メンバーかどうかはプロジェクトのロスターで判定する。ロスター自体が読めなかったときは書き込み可能
として開く — 編集できるバッファを誤って固めるより、保存がサーバーに断られるほうが原因が分かる。

### 赤リンク

実体のないページを指すリンクは色を変えて示す（`ChatoraLinkEmpty`、既定は赤）。判定には
プロジェクトのタイトル索引を使い、これは 60 秒キャッシュするので反映が最大 1 分遅れる。
ページを作る／消す操作と、ページに戻ってきたときには即座に取り直す。

### 箇条書き

Cosense はインデント 1 文字が 1 段。各段に中点を描き、段ごとに 1 セルずつ字下げする。

```lua
pads = {
  bullet = '•',      -- 中点のグリフ
  guide = false,     -- 文字を渡すと上位レベルに縦線を引く（Cosense には無い）
  spacing = true,    -- 段ごとの字下げ
  gap = 0,           -- 中点と本文の間の追加余白
}
```

中点はインライン仮想テキストとして**最後のインデント文字の手前**に描く。そのため中点を
2 セル幅で描くフォントでも本文の 1 文字目を潰さず、`gap = 0` でも本文との間にインデント
1 文字分が残る。空のリスト項目にカーソルを置いたとき、その位置は兄弟行の本文が始まる桁と
一致する。

`1.` で始まる行は自前の番号を持つので中点を描かない。

### 引用

`> 引用` の `>` を縦棒に置き換え、本文を淡く落とす。

```lua
quote = {
  bar = '▌',                                   -- 太さはグリフで決まる: ▏ ▎ ▍ ▌ ┃ │
  hl = { fg = '#4493f8' },                     -- 縦棒（ChatoraQuoteBar）
  text_hl = { fg = '#9198a1', italic = true }, -- 引用本文（ChatoraQuoteText）
  dim = false,                                 -- 本文はそのままにして縦棒だけ出す
  wrap = false,                                -- 折り返し行への追従をやめる
}
```

`hl` / `text_hl` は `nvim_set_hl` にそのまま渡る。省略するとどちらも `Comment` にリンクする。
縦棒は conceal ではなく overlay なので、カーソルがその行に来ても消えない。

`wrap = true`（既定）のとき、折り返された引用の 2 行目以降にも縦棒が続くよう、ページの
ウィンドウに `breakindent` と `breakindentopt=shift:2` を設定する。この字下げが無いと縦棒が
折り返し行の 1 文字目を潰すため、追従が要らなければ `wrap = false` にする。

### カスタム装飾記法

`[<記号> 本文]` の記号を自分で定義できる。

```lua
notations = {
  ['|'] = { name = 'highlight', hl = { bg = '#3a3a00', bold = true } },
  ['='] = { name = 'boxed',     hl = { link = 'WarningMsg' } },
  ['@'] = { name = 'heading', icon = '📌', hl = { bold = true }, rule = true },
}
```

| フィールド | 意味 |
|---|---|
| キー | 1 文字の記号。公式記法の記号（`* / - _ $ [`）とは衝突不可 |
| `name` | 英数字と `_` のみ。semantic token の型名になる |
| `hl` | `nvim_set_hl` にそのまま渡る（`:colorscheme` 変更後も再適用）。キー名も `nvim_set_hl` のもの — 文字色は `fg`（`textColor` などは無い） |
| `icon` | 開きマーカーを置き換えて表示する 1 文字。カーソル行では元の記号が見える |
| `rule` | `true` でその行の下にウィンドウの右端まで届く罫線を引く。色は `rule_hl` |

Cosense のマーカーは 1 文字ではなく記号の連なりなので、公式記法と混ぜられる。`[|* 特徴]` は
`|`（上の例なら `highlight`）と `*`（太字）の両方を持つ。1 スパンに当たるハイライトは 1 つなので、
混在時はカスタム記法の `hl` が勝つ。

Neovim の conceal 置換は 1 文字までなので、`icon` が複数文字なら警告して `icon` だけ無視する
（`name` / `hl` は活きる）。記号が 1 文字でない・`name` が不正・公式記法と衝突する場合は
エントリごと無視する。`hl` を Neovim が受け付けなかった場合（キー名の間違いなど）はその旨と
原因のキー名を知らせる。いずれも `vim.notify` で伝え、プラグインは落とさない。

### 記法の色

既定は colorscheme から借りるが、**同じ色が二度使われないことを保証する**。Cosense が
フォントサイズで付ける強調の段階を、ターミナルでは色で表すしかないため、リンクの色や他の段階と
被ると別の意味に読めてしまう。

| 記法 | 既定の見た目 |
|---|---|
| `[link]` / `[/proj/page]` | リンク色（下線なし） |
| 外部 URL | 同じ色 + **下線** |
| `` `code` `` / `code:js` | 灰色の背景バッジ（文字色はそのまま） |
| `[* 見出し]` | 太字のみ |
| `[** 見出し]` | 太字 + 色（リンク色とは必ず別） |
| `[*** 見出し]` 以上 | 太字 + さらに別の色 |
| 実体のないページへのリンク | `ChatoraLinkEmpty`（既定は赤） |

バッジの背景は `Normal` の背景から一段ずらして作る（暗いテーマでは明るく、明るいテーマでは
暗く）。`CursorLine` を借りるとカーソル行でバッジが消えるため。

すべて `default = true` で定義しているので `:hi` で上書きできる:

```lua
vim.api.nvim_set_hl(0, '@lsp.type.bold3.cosense', { fg = '#ff8700', bold = true })
vim.api.nvim_set_hl(0, '@lsp.type.code.cosense', { bg = '#303030' })
```

### 画像の表示

アイコン記法や画像リンクをバッファ内に描画するには、対応ターミナル（kitty / Ghostty）と
ImageMagick（`brew install imagemagick`）、そして描画プラグインが要る。

```lua
-- 推奨: image.nvim（magick_cli プロセッサなら luarocks 不要）
{ '3rd/image.nvim', opts = { processor = 'magick_cli' } },
-- 代替: snacks.nvim の image モジュール（両方あれば image.nvim 優先）
```

画像の取得は chatora の LSP サーバーが PAT 付きで行いローカルにキャッシュするため、
プライベートプロジェクトのアイコンも表示できる。

`[[…]]`（大きい記法）は画像にもアイコンにも効く。`[[name.icon]]` が単独で行にあるときは
`image_height_large` の大きさで描き、文中にあるときは 1 行のまま（インラインの行に背の高い
グリフを置く場所が無いため）。

#### 画像だけの行

`[img1] [img2] [img3]` のように画像しか無い行は、web だと横に流れて折り返す。ターミナルの
描画バックエンドは画像を **1 行分のインライン仮想テキスト**か**行の下の仮想行**のどちらかで
しか描けないため、次の二択になる。

| | 横並び | 大きさ |
|---|---|---|
| `image_gallery = false` | ✅ | ❌ 1 行 |
| `image_gallery = true`（既定） | ❌ 縦に積む | ✅ |

積むときは各画像を行のインデントに揃えるので、階段状にならず一列になる。

### 画像の貼り付け

`<leader>cv` でクリップボードの画像をアップロードし、カーソルの下の行に画像記法を書き込む。
アップロード中はその行にスピナーが出る。

Neovim のレジスタはテキストしか持てないので、画像のバイト列を取り出すのに外部ツールが要る
（最初に見つかったものを使う）。

| プラットフォーム | ツール |
|---|---|
| macOS | `pngpaste`（`brew install pngpaste`）。無ければ標準の `osascript` |
| Wayland | `wl-paste` |
| X11 | `xclip` |

行き先はプロジェクト側の設定（`/api/projects/<name>` の `uploadImageTo`）で決まり、
アップロードごとに読み直すのでプロジェクトを切り替えれば行き先も切り替わる。

| `uploadImageTo` | 行き先 | 挿入される記法 |
|---|---|---|
| `gcs` | プロジェクト自身のファイル領域 | `[https://scrapbox.io/files/….png]` |
| `gyazo` | Gyazo | `[https://gyazo.com/…]` |

PAT ではこの設定を読めない（`/api/projects/<name>` が 401 を返す）。読めなかったときは
プロジェクト自身のファイル領域を使う — Cosense の Gyazo トークン発行はブラウザのセッションを
前提としており、PAT では通らないため。片方が失敗したらもう片方を試す。

### ページ情報

`<leader>ci` で開く。よく見るものが上、横線で区切って下に行くほど細かくなる。

```
  URL          https://scrapbox.io/my-project/設計メモ
  作成         ◍ taro   3日前
  更新         ◍ はなこ        12分前
  共同編集者   ◍ ◍ ken、mika
  ─────────────────────────────────────
  プロジェクト my-project
  ページ履歴   12
  被リンク     6
  ─────────────────────────────────────
  閲覧数       128
  ページランク 1.23
  行数 / 文字数 42 / 1980
  ピン留め     なし
  最終閲覧     5時間前
```

日時は相対表記に丸める。作成者・最終更新者のアイコンを名前の左に描く（画像を描けるターミナル
のみ。描けなくても名前は出るし桁もずれない）。共同編集者の行は、作成者・最終更新者以外に
編集した人がいるときだけ出る。

ページ本文には著者の id しか入っていないので、名前は `/api/projects/<name>/users` で解決し、
プロジェクト単位に 10 分キャッシュする。

### アイコン挿入

アイコンキーは押した場所で意味が変わる。

| 状況 | 挿入されるもの |
|---|---|
| リンク補完が開いていて候補が選択されている | その候補のアイコン `[候補.icon]`（書きかけの `[...]` ごと置換） |
| それ以外 | 自分のアイコン `[自分.icon]` |

blink.cmp / nvim-cmp / 組み込み補完のどれでも動く。ターミナルのポップアップには画像を描けない
ので、補完メニューの中にアイコンは出ない。

### 保存状態の表示

保存の成否はトーストではなく小さなアイコンで伝える: サイドバーの `●` マーク、コマンドラインへの
一行 echo、そして statusline コンポーネント。

```lua
-- 素の statusline
vim.o.statusline = "%f %{%v:lua.require'chatora.status'.component()%}"
```

`component()` はアイコンだけを返す。ページの数値も出すなら `page_info()`:

```lua
-- 素の statusline
vim.o.statusline = "%f %{%v:lua.require'chatora.status'.component()%} %{v:lua.require'chatora.status'.page_info()}"

-- lualine
{ sections = { lualine_x = {
  { function() return require('chatora.status').page_info() end,
    color = function() return require('chatora.status').page_info_hl() end },
} } }
```

`page_info()` は `更新 43分前 · 閲覧 39 · 被リンク 6` のようなプレーン文字列を返し、ページ以外の
バッファでは空文字（条件を書かずにそのまま置ける）。色は `page_info_hl()` がハイライトグループ名
で返す。

Cosense の日時はサーバー側のコピーの話なので、ローカルに未保存の変更があると黙って嘘になる。
そのため未保存のときは先頭にバッジが付く。

| 状態 | `page_info()` | `page_info_hl()` |
|---|---|---|
| 保存済み | `更新 43分前 · 閲覧 39` | `ChatoraStatusMuted` |
| 未保存 | `● 未保存 · 更新 43分前 · 閲覧 39` | `ChatoraStatusDirty` |
| 保存中 | `◍ 保存中 · …` | `ChatoraStatusPending` |
| 保存失敗 | `✗ 保存失敗 · …` | `ChatoraStatusError` |

更新時刻だけなら `require('chatora.status').updated(bufnr)`。色を自前で付けるなら
`require('chatora.status').icon(bufnr)` がアイコンとハイライトグループ名を返す。

### サイドバーのタブ

```lua
sidebar_tabs = {
  { label = 'すべて' },
  { label = '未読', filter = 'me', unread_only = true },
  { label = '自分', filter = { type = 'icon', value = 'your-name' } },
}
```

`filter` は `'me'`（自分の保存済み Cosense フィルタ。無ければ自分の名前の icon フィルタ）か
`{ type, value }`。`sidebar_tabs = false` でタブなしの単一リストになる。

## 連携

### telescope

同じ全文検索を telescope のピッカーとしても使える。

```lua
require('telescope').load_extension('chatora')
```

`:Telescope chatora search`（`:Telescope chatora` も同じ）。並び順は Cosense の pageRank を
そのまま使い、telescope 側では一致箇所のハイライトだけを行う。プレビューはページ本文で、
ヒット行に飛んで `TelescopePreviewMatch` でマークする。`dynamic_preview_title = true` を
設定していればプレビューの枠にページ名が出る。

`:Chatora search` は telescope が無くても動く内蔵ピッカーで、こちらとは別物。

### シェルから起動

`bin/chatora` が `nvim +Chatora` のランチャー。

```sh
alias chatora='/path/to/chatora/bin/chatora'
```

以後 `chatora` だけでサイドバー付きの nvim が立ち上がる。`chatora <url>` でそのページを開く。

## トラブルシューティング

### `<C-i>` でアイコンが挿入されない

端末は kitty keyboard protocol を話すときだけ `<C-i>` を `<Tab>` と別のキーとして送る。
それ以外では**同じバイト**で届き、`<Tab>` は補完プラグインのものなので補完メニューが出る。

- kitty / Ghostty / WezTerm はそのまま対応。**tmux 越しなら `set -g extended-keys on` が必要**
- 既定でもう一つ入っている **`<M-i>`（Alt+i）** を使う。どのプラグインとも競合しない
- Ghostty なら `keybind = cmd+i=text:\x1bi` で Cmd+I を `<M-i>` として送れる

chatora は `<Tab>` を奪わない。テーブル行のときだけ本物のタブを入れ（`expandtab` だとセル区切りに
ならないため）、それ以外は元々そのキーを持っていたマッピングに委譲する。

### 何かが読み込めない（ページ・画像・関連ページ）

`log = true` にして `:Chatora log`。**2xx 以外のレスポンスはすべて** メソッド・URL・status
付きで記録される。chatora は失敗を値に変えて UI を静かに保つ設計なので（読めないページは
「存在しないページ」に、取れない画像は「描かれない画像」になる）、理由はここでしか分からない。

画像の描画には対応ターミナルと描画プラグインの両方が要る（[画像の表示](#画像の表示)）。

### 保存が競合で止まる

同じ行をサーバー側でも編集している。`]c` で競合行へ飛び、直してから `:w`。
詳しくは[同期と競合](#同期と競合)。

## 開発

`:Chatora reload` で nvim を再起動せずにプラグインを入れ替えられる。LSP を止め、chatora の
ウィンドウとバッファを畳み、`package.loaded` から chatora のモジュールを落として同じオプションで
`setup()` をやり直す。**サーバー側を変えたときは先に `bun run build`**（クライアントはプロセスを
起動し直すだけでビルドはしない）。

```sh
bun run verify           # typecheck + テスト + build + lint + smoke + E2E
bun test                 # core + server の単体テスト
nvim --headless --clean -u NORC -c "luafile tests/smoke.lua"
bun tests/e2e/run.ts     # 偽 Cosense サーバー + headless nvim
```

## ライセンス

[MIT](LICENSE)
